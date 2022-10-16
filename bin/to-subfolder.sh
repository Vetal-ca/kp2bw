#!/usr/bin/env bash

set -o errexit
set -o nounset
set -o pipefail

usage ()
{
#    echo "Usage: ${0##*/} --folder|f folder --user|u email --password|p password [--org|o org-name] [--exclude|e folder-prefixes-to-exclude-csv]"
    echo "Usage: ${0##*/} --folder|f folder --client-id|i client-id --client-secret|s client-secret  --url|u url [--org|o org-name] [--exclude|e folder-prefixes-to-exclude-csv]"
    echo "Example: ${0##*/} --folder private --client-id some-id... --client-secret some-secret...  --url https://bw.somedomain.tld [--org|o org-name] [--exclude|e folder-prefixes-to-exclude-csv]"

    exit 1
}

OPTS=$(getopt --options f:i:s:e:u: --longoptions folder:,client-id:,client-secret:,exclude:,url: --name 'parse-options' -- "$@")
if [ $? != 0 ]; then
  echo "Failed parsing options." >&2
  exit 1
fi

eval set -- "${OPTS}"

while true; do
  case "$1" in
  -f | --folder)
    folder="$2"
    shift 2
    ;;
  -i | --client-id)
    client_id="$2"
    shift 2
    ;;
  -s | --client-secret)
    client_secret="$2"
    shift 2
    ;;
  -u | --url)
    url="$2"
    shift 2
    ;;
#  -o | --org)
#    org="$2"
#    shift 2
#    ;;
#  -e | --exclude)
#    exclude="$2"
#    shift 2
#    ;;
  --)
    shift
    break
    ;;
  *) break ;;
  esac
done

if [ -z ${folder+set} ]; then
  echo "Folder is not set"
  usage
fi

if [ -z ${client_id+set} ]; then
  echo "client-id is not set"
  usage
fi

if [ -z ${client_secret+set} ]; then
  echo "client_secret is not set"
  usage
fi

if [ -z ${url+set} ]; then
  echo "url is not set"
  usage
fi

# urldecode https://stackoverflow.com/questions/28309728/decode-url-in-bash
# Encode
# python3 -c "import urllib.parse; print(urllib.parse.quote(input()))" <<< "${data}"

# Decode
#python3 -c "import urllib.parse; print(urllib.parse.unquote(input()))" <<< "${data}"

# dos2unix to-subfolder.sh && ./to-subfolder.sh --folder "Vitali & Kate shared" --user "${email}" --password="${password}"

#dos2unix to-subfolder.sh && ./to-subfolder.sh --folder "Vitali & Kate shared" --user "${email}" --password="${password}"

#address="keestore.vetals.com" &&\
#data="scope=api%20offline_access&client_id=cli&deviceType=8&deviceIdentifier=c7ceab4f-09df-4d1e-81af-543460573ba3&deviceName=linux&grant_type=password&username=lyuda%40art-nes.com&password=54QiTKoncpyw0Z4Tt7%2FVxdG3ktLV5KU74I3t5VVgbVU%3D" &&\
#curl --request POST \
#"https://${address}/identity/connect/token" \
#  --header 'Content-Type: application/x-www-form-urlencoded' \
#  --header 'device-type: 8' \
#  --data "${data}"

#bw logout || true
#echo "User ${user}, logging in"
#session=$(bw login "${user}" "${password}" --raw)

#if [ ! -z "${org-}" ]; then
#  echo "Org is passed in, retrieving info"
#  org_id=$(bw list organizations --session "${session}" | jq -r --arg org "${org}" '.[] | select(.name == $org) | .id')
#  if [ -z "${org_id}" ]; then
#    echo "Organization \"${org}\" is incorrect, bailing out ..."
#  fi
#fi

#bw list folders --session "${session}" | jq -rc '.[] | select(.id != null)' | while read -r f; do
#  name=$(echo "${f}" | jq -r '.name')
#  id=$(echo "${f}" | jq -r '.id')
#
#  echo "Processing folder \"${name}\" ..."
#  # https://stackoverflow.com/a/2172365/1672461
#  if [[ ! "${name}" =~ ^"${folder}".*$ ]]; then
#    new_name="${folder}/${name}"
#    echo "Renaming folder: \"${name}\" => \"${new_name}\""
#    data=$(jq -n --arg name "${new_name}" '{"name":$name}' | base64 --wrap=0)
#    echo bw edit folder "${id}" "${data}" --session "${session}"
#    bw get folder "${id}" --session "${session}"
#    break
#  fi
#done
#

#user="admin" &&\
#info="/projects/personal/work/bw.enc.json" &&\
#oauth_data=$(sops --decrypt "${info}" | jq -r ".bw.${user}.oauth") &&\
#client_id=$(echo "${oauth_data}" | jq -r '.client_id') &&\
#client_secret=$(echo "${oauth_data}" | jq -r '.client_secret')
# dos2unix to-subfolder.sh && ./to-subfolder.sh --folder "Vitali & Kate shared" --client-id "${client_id}" --client-secret="${client_secret}" --url https://keestore.vetals.com

# https://bitwarden.com/help/personal-api-key/
# Public API: https://bitwarden.com/help/api/
# Management API: https://bitwarden.com/help/vault-management-api/
# ngrep -q -d eth0 -W byline port 8080


# Doesn't work without these (Error 500)
device_identifier="c7ceab4f-09df-4d1e-81af-543460573ba3"
device_name="linux"
data="scope=api&client_id=${client_id}&grant_type=client_credentials&client_secret=${client_secret}&deviceName=${device_name}&deviceIdentifier=${device_identifier}"


login_data=$(curl --request POST "${url}/identity/connect/token" \
  --header 'Content-Type: application/x-www-form-urlencoded' \
  --data "${data}" --silent)

token=$(echo ${login_data} | jq -r '.access_token')

curl --request GET "${url}/api/folders" \
  --header 'Content-Type: application/json' \
  --header "Authorization: Bearer ${token}" \
  --silent | jq -r '.Data[]'

curl --request GET "${url}//api/sync?excludeDomains=true" \
  --header 'Content-Type: application/json' \
  --header "Authorization: Bearer ${token}" \
  --silent | jq
