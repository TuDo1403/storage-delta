#!/bin/bash

# Check if the commit hash argument is provided
if [ -z "$1" ]; then
  echo "Usage: bash dependencies/storage-delta-0.3.2/run.sh --dst-commit <commit_to_compare_against> --src-commit <commit_to_compare> --github-root <github_root> [--omit new]"
  exit 1
fi

# Process positional arguments
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
  --dst-commit)
    shift
    dst_commit="$1"
    shift
    ;;
  --src-commit)
    shift
    src_commit="$1"
    shift
    ;;
  --github-root)
    shift
    github_root="$1"
    shift
    ;;
  *) ;;
  esac
done

dst_root="src"
src_root=$(yq eval '.profile.default.src' ./foundry.toml)

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
  if [ "$(git rev-parse --short HEAD)" = "${dst_commit:0:7}" ]; then
    exists=1
    dst_root=$(yq eval '.profile.default.src' ./foundry.toml)
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

  dst_root=$(yq eval '.profile.default.src' $old_version/foundry.toml)

  # Reset to a certain commit
  git reset --hard $dst_commit

  # Check if soldeer.lock exists
  if [ -f "soldeer.lock" ]; then
    forge soldeer install
  fi

  # Check if update-deps.sh exists
  if [ -f "update-deps.sh" ]; then
    ./update-deps.sh
  fi

  git checkout -- "./remappings.txt"

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

echo Current Directory: $current_dir
echo Old Version Directory: $old_version
echo SRC Root: $src_root
echo DST Root: $dst_root
echo SRC Commit: $src_commit
echo DST Commit: $dst_commit

echo "Finding .sol files in old and new versions"

# Call the function for the old version directory
cd $old_version
echo "Old Version Directory: $(ls -la)"
find_sol_files "$dst_root" "filesWithPath_old"

# Call the function for the new version directory
cd "$current_dir"
echo "Current Directory: $(ls -la)"
find_sol_files "$src_root" "filesWithPath_new"

echo "Old files: ${#filesWithPath_old[@]}"
echo "New files: ${#filesWithPath_new[@]}"

# ========================================================================

# REPORT DELETED ONES

differences=()
src_root_prefix=$src_root/
dst_root_prefix=$dst_root/

# Extract basenames of the new files into a regular array
newFilesBase=()
for itemNew in "${filesWithPath_new[@]}"; do
  newFilesBase+=("${itemNew#$src_root_prefix}")
done

# Check old files against the new files basenames
for itemOld in "${filesWithPath_old[@]}"; do
  itemBase="${itemOld#$dst_root_prefix}"
  skip=

  for base in "${newFilesBase[@]}"; do
    if [[ "$itemBase" == "$base" ]]; then
      skip=1
      break
    fi
  done

  [[ -n $skip ]] || differences+=("$itemBase")
done

echo "Deleted files: ${#differences[@]}"

# If there are differences, write them to .removed file
if [ ${#differences[@]} -gt 0 ]; then
  mkdir -p "storage_delta"
  printf "%s\n" "${differences[@]}" >"storage_delta/.removed"
fi

# Remove path in `differences` for `filesWithPath_old` and `filesWithPath_new`
echo "Removing deleted files from the old and new files"

# Create new arrays to hold valid files
valid_filesWithPath_old=()
valid_filesWithPath_new=()

# Remove files in differences from `filesWithPath_old`
for fileOld in "${filesWithPath_old[@]}"; do
  basenameOld="${fileOld#$dst_root_prefix}"
  # Check if the path is not in `differences`
  if [[ ! " ${differences[@]} " =~ " ${basenameOld} " ]]; then
    valid_filesWithPath_old+=($fileOld)
  fi
done

# Remove files in differences from `filesWithPath_new`
for fileNew in "${filesWithPath_new[@]}"; do
  basenameNew="${fileNew#$src_root_prefix}"
  # Check if the path is not in `differences`
  if [[ ! " ${differences[@]} " =~ " ${basenameNew} " ]]; then
    valid_filesWithPath_new+=($fileNew)
  fi
done

# Replace old arrays with filtered ones
filesWithPath_old=("${valid_filesWithPath_old[@]}")
filesWithPath_new=("${valid_filesWithPath_new[@]}")

# Sort the files by their basenames
echo "Sorting old and new files"
filesWithPath_old=($(for file in "${filesWithPath_old[@]}"; do echo "$file"; done | sort))
filesWithPath_new=($(for file in "${filesWithPath_new[@]}"; do echo "$file"; done | sort))

# Get the paths from file paths for new and old files
paths_new=()
paths_old=()

for fileNew in "${filesWithPath_new[@]}"; do
  paths_new+=("$(dirname "$fileNew")")
done

for fileOld in "${filesWithPath_old[@]}"; do
  paths_old+=("$(dirname "$fileOld")")
done

# Get the paths from file paths for new and old files
paths_new=()
paths_old=()

for fileNew in "${filesWithPath_new[@]}"; do
  paths_new+=("$(dirname "$fileNew")")
done

for fileOld in "${filesWithPath_old[@]}"; do
  paths_old+=("$(dirname "$fileOld")")
done

# ========================================================================

# Limit the number of child processes
NUM_SUB_PROCESSES_EACH_CORE=2
NUMBER_OF_CORES=1
if [ "$(uname)" == "Darwin" ]; then
  NUMBER_OF_CORES=$(sysctl -n hw.logicalcpu)
elif [ "$(uname)" == "Linux" ]; then
  NUMBER_OF_CORES=$(nproc)
fi
MAX_CHILD_PROCESSES=$(echo "$NUMBER_OF_CORES * $NUM_SUB_PROCESSES_EACH_CORE" | bc)
child_processes=0

# Ensure both arrays have the same length
len_old=${#filesWithPath_old[@]}
len_new=${#filesWithPath_new[@]}

if [ $len_old -ne $len_new ]; then
  # Chose
  exit 1
fi

# Loop through pairs of files from both arrays
for i in "${!filesWithPath_old[@]}"; do
  fileOld="${filesWithPath_old[$i]}"
  fileNew="${filesWithPath_new[$i]}"

  # Check if the files are not empty and differences do not include the fileOld
  if [ -n "$fileOld" ] && [[ ! " ${differences[@]} " =~ " ${fileOld} " ]]; then
    (
      # Run the 'forge inspect' command with the current item from the array
      formatted_name_old=${fileOld}:$(basename "${fileOld%.*}")
      cd "$old_version"
      output_old=$(forge inspect "$formatted_name_old" storage 2>/dev/null)
      formatted_name_new=${fileNew}:$(basename "${fileNew%.*}")
      cd "$current_dir"
      output_new=$(forge inspect "$formatted_name_new" storage 2>/dev/null)

      if [ -n "$output_old" ] && [ -n "$output_new" ]; then
        echo "Comparing storage layout for $formatted_name_old" against $formatted_name_new
        node ./dependencies/storage-delta-0.3.2/_reporter.js "$output_old" "$output_new" "${fileOld}" "${fileNew}" "${dst_commit}" "${src_commit}" "${github_root}" "$OMIT_NEW"
      else
        echo "Skipping $formatted_name_old against $formatted_name_new due to missing storage layout, output_old length ${#output_old}, output_new length ${#output_new}"
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

# Wait for all remaining child processes to finish
wait
