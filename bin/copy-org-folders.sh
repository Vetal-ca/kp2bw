#!/usr/bin/env bash

set -o errexit
set -o nounset
set -o pipefail

usage ()
{
    echo "Usage: ${0##*/} --src-user src-user-email [--src-pass src-user-password] --dst-user dst-user-email [--dst-pass dst-user-password] --org org-name"

    exit 1
}

# Create folder, from parent to current.
# $1 - array of path elements
# $2 - path -> id, associative array to put result to
create_folder_recursive () {
  local -n path_elements=$1
  local -n ret1=$2
  len=${#path_elements[@]}
  if [ $len > 1 ]; then
    # create parents, recursive
    create_folder_recursive ${path_elements[@]::${len-1} ret1
  fi
}

# Create folders, from parent to current.
# $1 - path
# $2 - path -> id, associative array to put result to
create_folders ()
{
  # https://stackoverflow.com/questions/40156874/bash-pass-arrays-to-function
  # https://stackoverflow.com/questions/4069188/how-to-pass-an-associative-array-as-argument-to-a-function-in-bash
  local -n ret=$2
  echo "Creating folders line, \"$1\""
  local folder_parts
  IFS='/' read -ra folder_parts <<< "$1"
  create_folder_recursive folder_parts ret
}


#OPTS=$(getopt --longoptions src-user:,src-pass:,dst-user:,dst-pass:,org: --name 'parse-options' -- "$@")
OPTS=$(getopt --options "" --longoptions src-user:,src-pass:,dst-user:,dst-pass:,org: --name 'parse-options' -- "$@")
if [ $? != 0 ]; then
  echo "Failed parsing options." >&2
  exit 1
fi


eval set -- "${OPTS}"

while true; do
  case "$1" in
  --src-user)
    src_user="$2"
    shift 2
    ;;
  --src-pass)
    src_pass="$2"
    shift 2
    ;;
  --dst-user)
    dst_user="$2"
    shift 2
    ;;
  --dst-pass)
    dst_pass="$2"
    shift 2
    ;;
  --org)
    org_name="$2"
    shift 2
    ;;
  --)
    shift
    break
    ;;
  *) break ;;
  esac
done

if [ -z ${src_user+set} ]; then
  echo "Source user is not set"
  usage
fi

if [ -z ${dst_user+set} ]; then
  echo "Destination user is not set"
  usage
fi

if [ -z ${org_name+set} ]; then
  echo "Org name is not set"
  usage
fi

if [ -z ${src_pass+set} ]; then
  read -sp "Enter password for source user :" src_pass
fi

if [ -z ${dst_pass+set} ]; then
  read -sp "Enter password for destination user :" dst_pass
fi

# 1. Read source data
# 2. Create folders
# 3. Move items

declare -A ret

create_folders  "one/two/three" ret

for i in "${!ret[@]}"
do
  echo "\"${i}\"=\"${folder_to_id[$i]}\""
done

exit 0
echo "Source user, login"
bw logout || true
session=$(bw login "${src_user}" "${src_pass}" --raw)

echo "Retrieving org ID"

org_id=$(bw list organizations --session "${session}" | jq -r --arg org "${org_name}" '.[] | select(.name == $org) | .id')

echo "Getting source data"

# Skip "No folder"
src_folders=$(bw list folders --session "${session}" | jq -r '[.[] | select(.id != null) | {path: .name, id} ]')
#echo "${src_folders}" | jq

src_items=$(bw list items --session "${session}" --organizationid "${org_id}" | jq -r '[ .[] | { name, id, folderId, organizationId} ]')

# https://stackoverflow.com/a/53534029/1672461
#jq -n --argfile folders <(echo "${src_folders}") --argfile items <(echo "${src_items}") '{folders: $folders, items: $items}'
#jq -n --argjson folders "${src_folders}" --argjson items "${src_items}" '{folders: $folders, items: $items}'

# https://qmacro.org/blog/posts/2022/06/23/understanding-jq%27s-sql-style-operators-join-and-index/
# Array of item id, name and location
src_item_folder=$(jq -n --argjson folders "${src_folders}" --argjson items "${src_items}" '[ {folders: $folders, items: $items} | JOIN(INDEX(.folders[]; .id); .items[]; .folderId; add) | {name, path, id}]')

echo "Destination user, login"
bw logout
session=$(bw login "${dst_user}" "${dst_pass}" --raw)

# Destination user folders, path -> id
declare -A folder_to_id

echo "Retrieving target user, existing folders"
dst_folders=$(bw list folders --session "${session}" | jq -rc '.[] | select(.id != null) | {path: .name, id}')

# https://stackoverflow.com/questions/25638795/bash-while-loop-with-read-and-ifs
# shopt -s lastpipe

# https://stackoverflow.com/questions/2376031/reading-multiple-lines-in-bash-without-spawning-a-new-subshell
while read -r f; do
  path=$(echo "${f}" | jq -r '.path')
  id=$(echo "${f}" | jq -r '.id')
  folder_to_id["${path}"]="${id}"
done < <(echo "${dst_folders}")

echo "Recreating org folders ..."
while read -r f; do
  path=$(echo "${f}" | jq -r '.path')
  id=$(echo "${f}" | jq -r '.id')
  name=$(echo "${f}" | jq -r '.name')

done < <(echo "${src_item_folder}")

#for i in "${!folder_to_id[@]}"
#do
#  echo "\"${i}\"=\"${folder_to_id[$i]}\""
#done


