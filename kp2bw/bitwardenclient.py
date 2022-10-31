import base64
import json
import logging
import os
import platform
import shutil
from abc import abstractmethod
from itertools import groupby
from subprocess import STDOUT, CalledProcessError, check_output


class BitwardenClient:
    TEMPORARY_ATTACHMENT_FOLDER = "attachment-temp"

    def __init__(self, password):

        # check for bw cli installation
        self._exec("bw --help", error_hint="Bitwarden Cli not installed! See "
                                           "https://help.bitwarden.com/article/cli/#download--install for help")

        # login
        self._key = self._exec(f"bw unlock {password} --raw",
                               error_hint="Could not unlock the Bitwarden db. Is right user logged in? Is the Master Password "
                                          "correct and are bw cli tools set up correctly?")

        # make sure data is up to date
        self._exec_with_session("bw sync", error_hint="Could not sync the local state to your Bitwarden server")

        # get existing collections
        # if org_id:
        #     self._colls = {coll["name"]: coll["id"] for coll in
        #                    json.loads(self._exec_with_session(f"bw list org-collections --organizationid {orgId}"))}
        # else:
        #     self._colls = None

    def __del__(self):
        # cleanup temp directory
        self._remove_temporary_attachment_folder()

    def _create_temporary_attachment_folder(self):
        if not os.path.isdir(self.TEMPORARY_ATTACHMENT_FOLDER):
            os.mkdir(self.TEMPORARY_ATTACHMENT_FOLDER)

    def _remove_temporary_attachment_folder(self):
        if os.path.isdir(self.TEMPORARY_ATTACHMENT_FOLDER):
            shutil.rmtree(self.TEMPORARY_ATTACHMENT_FOLDER)

    def _exec(self, command, error_hint: str = None) -> str:
        try:
            logging.debug(f"-- Executing command: {command}")
            output = check_output(command, stderr=STDOUT, shell=True)
        except CalledProcessError as e:
            output = str(e.output.decode("utf-8", "ignore"))
            logging.debug(f"  |- Output: {output}")
            err = "{}\n{}".format(error_hint, output) if error_hint else output
            raise Exception(err)

        logging.debug(f"  |- Output: {output}")
        return str(output.decode("utf-8", "ignore"))

    def _exec_with_session(self, command, error_hint: str = None) -> str:
        return self._exec(f"{command} --session '{self._key}'", error_hint=error_hint)

    @staticmethod
    def _get_platform_dependent_echo_str(string):
        if platform.system() == "Windows":
            return f'echo {string}'
        else:
            return f'echo \'{string}\''

    def create_entry(self, container, entry):
        name = entry["name"]
        # check if already exists
        if self._has_item(container, name):
            logging.info(f"-- Entry {name} already exists in folder {container}. skipping...")
            return "skip"

        # create folder if exists
        if container:
            # set id
            cid = self._create_container(container)
        else:
            cid = None

        return self._create_item(entry, cid)

    # Create folder or collection with all prefixes. Return folder id
    # E.g., "one/two/three" :
    # 1. "one"
    # 2. "one/two"
    # 3. "one/two/three" -> return (id)
    def _create_container(self, path) -> str:
        path_split = path.split('/')
        if len(path_split) > 1:
            # recursively create parent containers
            parent = '/'.join(path_split[:-1])
            self._create_container(parent)
        # Once parent folders created, time to create this folder
        return self._create_container_imp(path)

    # Create folder or collection with all prefixes. Return folder id
    @abstractmethod
    def _create_container_imp(self, path) -> str:
        pass

    # Check item, by name, if already present in folder
    @abstractmethod
    def _has_item(self, path, name) -> bool:
        pass

    # Create item. Return command's output
    @abstractmethod
    def _create_item(self, item, cid) -> str:
        pass

    # # Return dictionary, name -> ContainerId, where container ID is either folderID or collectionId
    # @abstractmethod
    # def _get_item_to_container_id(self) -> Dict[str]:
    #     pass

    def create_attachment(self, item_id, attachment):
        # store attachment on disk
        filename = ""
        data = None
        if isinstance(attachment, tuple):
            # long custom property
            key, value = attachment
            filename = key + ".txt"
            data = value.encode("UTF-8")
        else:
            # real kp attachment
            filename = attachment.filename
            data = attachment.data

        # make sure temporary attachment folder exists
        self._create_temporary_attachment_folder()

        path_to_file_on_disk = os.path.join(self.TEMPORARY_ATTACHMENT_FOLDER, filename)
        with open(path_to_file_on_disk, "wb") as f:
            f.write(data)

        try:
            output = self._exec_with_session(
                f'bw create attachment --file "{path_to_file_on_disk}" --itemid {item_id}')
        finally:
            os.remove(path_to_file_on_disk)

        return output


# Private Bitwarden, folder-based
class BitwardenClientPrivate(BitwardenClient):
    def __init__(self, password):
        BitwardenClient.__init__(self, password)

        # get folders list
        self._folder_name_to_id = {folder["name"]: folder["id"] for folder in
                                   json.loads(self._exec_with_session("bw list folders"))}

        # get existing entries
        self._folder_entries = self._get_existing_folder_entries()

    # Return folder -> list(item_name)
    # So we can check if item is already imported
    def _get_existing_folder_entries(self):
        # id -> name
        folder_id_lookup_helper = {folder_id: folder_name for folder_name, folder_id in self._folder_name_to_id.items()}
        # If not specified - returns all, with organizationId set or null
        # If specified, OrgID are only items returned
        items = json.loads(self._exec_with_session("bw list items"))

        # fix None folderIds for entries without folders
        for item in items:
            if not item['folderId']:
                item['folderId'] = ''

        items.sort(key=lambda item: item["folderId"])

        folder_to_item_name = \
            {
                folder_id_lookup_helper[folder_id] if folder_id in folder_id_lookup_helper else None:
                    [entry["name"] for entry in entries]
                for folder_id, entries in groupby(items, key=lambda item: item["folderId"])
            }
        return folder_to_item_name

    def _has_item(self, path, name) -> bool:
        return path in self._folder_entries and name in self._folder_entries[path]

    # return folder ID
    def _create_container_imp(self, path) -> str:
        if not path:
            raise Exception("Folder name is expected")

        fid = self._folder_name_to_id.get(path)
        if fid:
            # Exists already
            return fid

        data = {"name": path}
        data_b64 = base64.b64encode(json.dumps(data).encode("UTF-8")).decode("UTF-8")

        output = self._exec_with_session(f'{self._get_platform_dependent_echo_str(data_b64)} | bw create folder')

        output_obj = json.loads(output)
        name = output_obj["name"]
        fid = output_obj["id"]

        self._folder_name_to_id[name] = fid
        return fid

    def _create_item(self, item, cid) -> str:
        item["folderId"] = cid

        json_str = json.dumps(item)

        # convert string to base64
        json_b64 = base64.b64encode(json_str.encode("UTF-8")).decode("UTF-8")

        output = self._exec_with_session(
            f'{self._get_platform_dependent_echo_str(json_b64)} | bw create item')

        return output


# Org Bitwarden, collections-based
class BitwardenClientOrg(BitwardenClient):
    def __init__(self, password, org):
        BitwardenClient.__init__(self, password)
        # save org
        self._orgId = self._get_org_id(org)

        # Collection template
        self._coll_template = json.loads(self._exec_with_session(f"bw get template org-collection"))

        # get collection list
        collections = json.loads(self._exec_with_session("bw list collections --organizationid {}".format(self._orgId)))
        self._coll_name_to_id = {folder["name"]: folder["id"] for folder in collections}

        # get existing entries
        self._coll_id_to_item_name = self._get_existing_collection_entries()

    # Return folder -> list(item_name)
    # So we can check if item is already imported
    def _get_existing_collection_entries(self):
        # id -> name
        coll_id_lookup_helper = {folder_id: folder_name for folder_name, folder_id in self._coll_name_to_id.items()}
        # If specified, OrgID are only items returned
        items = json.loads(self._exec_with_session("bw list items --organizationid {}".format(self._orgId)))

        coll_id_to_item_name = {}
        for item in items:
            for coll_id in item["collectionIds"]:
                path = coll_id_lookup_helper[coll_id]
                collection_items = coll_id_to_item_name.get(path)
                if not collection_items:
                    collection_items = []
                    coll_id_to_item_name[path] = collection_items

                collection_items.append(item["name"])

        return coll_id_to_item_name

    def _get_org_id(self, org) -> str:
        orgs_json = json.loads(BitwardenClient._exec_with_session(self, command="bw list organizations",
                                                                  error_hint="Unable to list organizations"))
        org_name_to_id = {org["name"]: org["id"] for org in orgs_json if "enabled" in org}
        if org not in org_name_to_id:
            raise Exception("Organisation '{}' is not found".format(org))
        return org_name_to_id[org]

    # Return folder -> list(item_name)
    # So we can check if item is already imported
    def _get_existing_folder_entries(self):
        # id -> name
        folder_id_lookup_helper = {folder_id: folder_name for folder_name, folder_id in self._folder_name_to_id.items()}
        # If not specified - returns all, with organizationId set or null
        # If specified, OrgID are only items returned
        items = json.loads(self._exec_with_session("bw list items"))

        # fix None folderIds for entries without folders
        for item in items:
            if not item['folderId']:
                item['folderId'] = ''

        items.sort(key=lambda item: item["folderId"])

        folder_to_item_name = \
            {
                folder_id_lookup_helper[folder_id] if folder_id in folder_id_lookup_helper else None:
                    [entry["name"] for entry in entries]
                for folder_id, entries in groupby(items, key=lambda item: item["folderId"])
            }
        return folder_to_item_name

    def _create_container_imp(self, path) -> str:
        cid = self._coll_name_to_id.get(path)
        if cid:
            # Exists already
            return cid

        entry = self._coll_template.copy()
        # set org and Name
        entry['name'] = path
        entry['organizationId'] = self._orgId

        json_str = json.dumps(entry)

        # convert string to base64
        json_b64 = base64.b64encode(json_str.encode("UTF-8")).decode("UTF-8")

        output = self._exec_with_session(
            f'{self._get_platform_dependent_echo_str(json_b64)} | bw create org-collection --organizationid {self._orgId}')
        data = json.loads(output)
        cid = data.get("id")
        if not cid:
            raise Exception("No ID is returned for bw create org-collection .., path: {}".format(path))
        self._coll_name_to_id[path] = cid
        return cid

    def _has_item(self, path, name) -> bool:
        return path in self._coll_id_to_item_name and name in self._coll_id_to_item_name[path]

    def _create_item(self, item, cid) -> str:
        item["collectionIds"] = [cid]
        item['organizationId'] = self._orgId

        json_str = json.dumps(item)

        # convert string to base64
        json_b64 = base64.b64encode(json_str.encode("UTF-8")).decode("UTF-8")

        output = self._exec_with_session(
            f'{self._get_platform_dependent_echo_str(json_b64)} | bw create item --organizationid {self._orgId}')

        return output

