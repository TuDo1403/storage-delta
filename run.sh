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
  --dst-root | -d)
    shift
    dst_root="$1"
    shift
    ;;
  --src-root | -s)
    shift
    src_root="$1"
    shift
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
  forge build

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
find_sol_files "$dst_root" "filesWithPath_old"

# Call the function for the new version directory
cd "$current_dir"
find_sol_files "$src_root" "filesWithPath_new"

# ========================================================================

# REPORT DELETED ONES

differences=()

# Extract basenames of the new files into a regular array
newFilesBase=()
for itemB in "${filesWithPath_new[@]}"; do
  newFilesBase+=("$(basename "$itemB")")
done

# Check old files against the new files' basenames
for item in "${filesWithPath_old[@]}"; do
  itemBase=$(basename "$item")
  skip=

  for base in "${newFilesBase[@]}"; do
    if [[ "$itemBase" == "$base" ]]; then
      skip=1
      echo "Found $itemBase in new version, skipping!"
      break
    fi
  done

  [[ -n $skip ]] || differences+=("$item")
done

# If there are differences, write them to .removed file
if [ ${#differences[@]} -gt 0 ]; then
  mkdir -p "storage_delta"
  printf "%s\n" "${differences[@]}" >"storage_delta/.removed"
fi

echo "Deleted files: ${#differences[@]}"

# ========================================================================

# Limit the number of child processes
NUM_SUB_PROCESSES_EACH_CORE=6
NUMBER_OF_CORES=1
if [ "$(uname)" == "Darwin" ]; then
  NUMBER_OF_CORES=$(sysctl -n hw.logicalcpu)
elif [ "$(uname)" == "Linux" ]; then
  NUMBER_OF_CORES=$(nproc)
fi
MAX_CHILD_PROCESSES=$(echo "$NUMBER_OF_CORES * $NUM_SUB_PROCESSES_EACH_CORE" | bc)
child_processes=0

# Loop through each item in the array
for line in "${filesWithPath_old[@]}"; do
  # Check if the line is not empty
  if [ -n "$line" ] && [[ ! " ${differences[@]} " =~ " ${line} " ]]; then
    (
      # Run the 'forge inspect' command with the current item from the array
      formatted_name=$(basename "${line%.*}")
      cd "$old_version"
      output_old=$(forge inspect $formatted_name storage 2>/dev/null)
      cd "$current_dir"
      output_new=$(forge inspect $formatted_name storage 2>/dev/null)

      if [ -n "$output_old" ] && [ -n "$output_new" ]; then
        echo "Comparing storage layout for $line"
        node ./dependencies/storage-delta-0.3.2/_reporter.js "$output_old" "$output_new" ${line} $OMIT_NEW
      else
        echo "Skipping $line due to missing storage layout, output_old length ${#output_old}, output_new length ${#output_new}"
      fi
    ) &

    child_processes=$(($child_processes + 1))

    # If the number of child processes is greater than the maximum number of child processes
    if [ $child_processes -ge $MAX_CHILD_PROCESSES ]; then
      # Wait for all child processes to finish
      wait
      # Reset child_processes
      child_processes=0
    fi
  fi
done

wait
