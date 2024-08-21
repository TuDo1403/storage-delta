#!/bin/bash

# HANDLE ERRORS

# Check if the commit hash argument is provided
if [ -z "$1" ]; then
  echo "Usage: bash dependencies/@storage-delta-0.3.1/run.sh <hash> [config]"
  exit 1
fi

# Process positional arguments
POSITIONAL_ARGS=()
OMIT_NEW=0

# Parsing the command-line arguments
while [[ $# -gt 0 ]]; do
  case "$1" in
  --omit)
    shift # Remove --omit from processing
    if [[ $1 == "new" ]]; then
      OMIT_NEW=1
      shift # Remove the value from processing
    else
      echo "Usage: --omit new"
      exit 1
    fi
    ;;
  --contracts | -c)
    shift # Remove --contracts from processing
    search_directory="$1"
    shift # Remove the value from processing
    ;;
  *)
    # Store positional arguments
    POSITIONAL_ARGS+=("$1")
    shift
    ;;
  esac
done

# Restore positional arguments
set -- "${POSITIONAL_ARGS[@]}"

# ========================================================================

# CLONE OLD VERSION

# Define the path to the new subdirectory
old_version=".storage_delta_cache/"

# Check if the directory exists, then remove it
exists=0
if [ -d "$old_version" ]; then
  # Check if the current commit matches the target commit hash
  prev_dir=$(pwd)
  cd "$old_version"
  if [ "$(git rev-parse --short HEAD)" = "${1:0:7}" ]; then
    exists=1
  fi
  cd "$prev_dir"
  if [ "$exists" -eq 0 ]; then
    rm -rf "$old_version"
  fi
fi

if [ "$exists" -eq 0 ]; then
  current_dir=$(pwd)
  # Clone the current directory to the new subdirectory
  git clone "file://$current_dir" "$old_version"
  cd "$old_version"

  # Reset to a certain commit
  git reset --hard "$1"

  # Check if soldeer.lock exists
  if [ -f "soldeer.lock" ]; then
    forge soldeer install
  fi 

  # Check if update-deps.sh exists
  if [ -f "update-deps.sh" ]; then
    chmod +x ./update-deps.sh
    ./update-deps.sh
  fi 
  
  forge install

  cd "$current_dir"
fi

# ========================================================================

# GET FILE NAMES

# Define a function to find .sol files
find_sol_files() {
  local dir="$1"
  local array_name="$2"
  local filesWithPath=()

  while IFS= read -r -d $'\0' file; do
    # Append the file name to the array
    filesWithPath+=("$file")
  done < <(find "$dir" -type f -name "*.sol" -print0)

  # Assign the array to the variable name specified by the second argument
  eval "$array_name"='("${filesWithPath[@]}")'
}

# Declare empty arrays to store the file names
filesWithPath_old=()
filesWithPath_new=()

current_dir=$(pwd)

# Call the function for the old version directory
cd $old_version
find_sol_files "$search_directory" "filesWithPath_old"

# Call the function for the new version directory
cd "$current_dir"
find_sol_files "$search_directory" "filesWithPath_new"

# ========================================================================

# REPORT DELETED ONES

if [ -d "storage_delta" ]; then
  rm -rf "storage_delta"
fi

differences=()
for item in "${filesWithPath_old[@]}"; do
  skip=
  for itemB in "${filesWithPath_new[@]}"; do
    [[ $item == $itemB ]] && {
      skip=1
      break
    }
  done
  [[ -n $skip ]] || differences+=("$item")
done

if [ ${#differences[@]} -gt 0 ]; then
  mkdir -p "storage_delta"
  printf "%s\n" "${differences[@]}" >"storage_delta/.removed"
fi

# ========================================================================

# COMPARE STORAGE LAYOUTS
MAX_CONCURRENT_PROCESSES=3
# Loop through each item in the array
for line in "${filesWithPath_old[@]}"; do
  # Check if the line is not empty
  if [ -n "$line" ] && [[ ! " ${differences[@]} " =~ " ${line} " ]]; then
    (
      # Run the 'forge inspect' command with the current item from the array
      formated_name=${line}:$(basename "${line%.*}")
      cd "$old_version"
      output_old=$(forge inspect $formated_name storage 2>/dev/null)
      cd "$current_dir"
      output_new=$(forge inspect $formated_name storage 2>/dev/null)

      if [ -n "$output_old" ] && [ -n "$output_new" ]; then
        echo "Comparing storage layout for $line"
        node ./dependencies/@storage-delta-0.3.1/_reporter.js "$output_old" "$output_new" ${line} $OMIT_NEW
      fi
    ) &

    # Limit the number of concurrent background processes
    if (($(jobs -r -p | wc -l) >= MAX_CONCURRENT_PROCESSES)); then
      echo "Waiting for background processes to finish... (PID: $!)"
      wait $!
    fi
  fi
done

wait
