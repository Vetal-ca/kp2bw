#!/usr/bin/env bash

set -o errexit
set -o nounset
set -o pipefail

usage ()
{
    echo "Usage: ${0##*/} --src-user src-user-email [--src-pass src-user-password] --dst-user dst-user-email [--dst-pass dst-user-password] --org org-name"

    exit 1
}

print_array ()
{
  local -n arr=$1
  for i in "${!arr[@]}"
do
  echo "\"${i}\"=\"${arr[$i]}\""
done

}

# Create folders, from parent to current.
# $1 - path
# $2 - session
# $3 - path -> id, associative array to put result to
create_folders ()
{
  local path=$1
  local login_session=$2
  local -n ret_val=$3

  local prefix

  if [[ "${path}" =~ \/ ]]; then
    # Multiple parts
    prefix=${path%/*}
    #suffix=${path##*/}
    create_folders "${prefix}" "${login_session}" $3
  fi

  local existing="${ret_val["${path}"]-}"

  if [ -z "${existing}" ]; then
    echo "Creating folder \"${path}\""

    data=$(jq -n --arg name "${path}" '{"name":$name}' | base64 --wrap=0)
    ret=$(bw create folder --session "${login_session}" "${data}")
    id=$(echo "${ret}" | jq -r '.id')

    # shellcheck disable=SC2034
    ret_val[${path}]="${id}"
  fi
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
declare -A folder_to_id=()

echo "Retrieving target user, existing folders"
dst_folders=$(bw list folders --session "${session}" | jq -rc '.[] | select(.id != null) | {path: .name, id}')

# https://stackoverflow.com/questions/25638795/bash-while-loop-with-read-and-ifs
# shopt -s lastpipe

# https://stackoverflow.com/questions/2376031/reading-multiple-lines-in-bash-without-spawning-a-new-subshell
if [ -n "${dst_folders}" ]; then
  while read -r f; do
    path=$(echo "${f}" | jq -r '.path')
    id=$(echo "${f}" | jq -r '.id')
    folder_to_id["${path}"]="${id}"
  done < <(echo "${dst_folders}")
fi

echo "Recreating org folders ..."
while read -r f; do
  path=$(echo "${f}" | jq -r '.path')
  create_folders "${path}" "${session}" folder_to_id
done < <(echo "${src_item_folder}" | jq -rc '.[]')

echo "Distributing items to folder ..."
bw sync --force --session "${session}"
while read -r f; do
  path=$(echo "${f}" | jq -r '.path')
  id=$(echo "${f}" | jq -r '.id')
  name=$(echo "${f}" | jq -r '.name')

  echo "Moving item \"${name}\" to folder \"${path}\""
  folder_id=${folder_to_id["${path}"]}
  data=$(jq -n --arg fid "${folder_id}" '{"folderId":$fid}' | base64 --wrap=0)
#  echo "${data}" | base64 --decode | jq
  #bw get item --session "${session}" "${name}"
  echo bw edit item --organizationid "${org_id}" --session "${session}" "${id}" "${data}"
  break

done < <(echo "${src_item_folder}" | jq -rc '.[]')


echo "Done!"
#print_array folder_to_id


