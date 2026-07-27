//
//  AFTLWrapper.cpp
//  NextAFT
//
//  C++ implementation of the C bridge around android-file-transfer-linux.
//

#include "AFTLWrapper.h"

#include <mtp/ptp/Device.h>
#include <mtp/ptp/ObjectFormat.h>
#include <mtp/ptp/ObjectProperty.h>
#include <mtp/ptp/Session.h>
#include <usb/Context.h>

#include <algorithm>
#include <chrono>
#include <cerrno>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <memory>
#include <mutex>
#include <stdexcept>
#include <string>
#include <thread>
#include <unordered_map>
#include <utility>
#include <vector>

namespace {

using ProgressCallback = void (*)(double, void *);
using CancellationCallback = bool (*)(void *);

thread_local std::string last_error;

void clear_error() {
    last_error.clear();
}

void set_error(const std::string &message) {
    last_error = message;
    std::fprintf(stderr, "AFTL: %s\n", message.c_str());
}

char *duplicate_string(const std::string &value) {
    auto *result = static_cast<char *>(std::malloc(value.size() + 1));
    if (result != nullptr) {
        std::memcpy(result, value.c_str(), value.size() + 1);
    }
    return result;
}

std::vector<std::string> split_path(const std::string &path) {
    std::vector<std::string> parts;
    std::string part;
    for (char character : path) {
        if (character == '/') {
            if (!part.empty()) {
                parts.push_back(std::move(part));
                part.clear();
            }
        } else {
            part.push_back(character);
        }
    }
    if (!part.empty()) {
        parts.push_back(std::move(part));
    }
    return parts;
}

std::string normalize_path(const std::string &path) {
    if (path.empty() || path == "/") {
        return "/";
    }

    std::string normalized;
    for (const auto &part : split_path(path)) {
        if (part == ".") {
            continue;
        }
        normalized += "/" + part;
    }
    return normalized.empty() ? "/" : normalized;
}

std::string join_path(const std::string &parent, const std::string &name) {
    if (parent.empty() || parent == "/") {
        return "/" + name;
    }
    return parent + "/" + name;
}

class ProgressReporter {
public:
    ProgressReporter(mtp::u64 total, ProgressCallback callback, void *userdata)
        : total_(total), callback_(callback), userdata_(userdata) {}

    void advance(mtp::u64 amount) {
        current_ += amount;
        if (callback_ == nullptr || total_ == 0) {
            return;
        }

        const double progress = std::min(1.0,
            static_cast<double>(current_) / static_cast<double>(total_));
        // AFTL can call the stream for very small USB packets. Limit callbacks
        // to 0.1% increments so Swift does not enqueue thousands of UI updates.
        if (progress >= last_reported_ + 0.001 || progress >= 1.0) {
            last_reported_ = progress;
            callback_(progress, userdata_);
        }
    }

    void finish() {
        if (callback_ != nullptr && last_reported_ < 1.0) {
            last_reported_ = 1.0;
            callback_(1.0, userdata_);
        }
    }

private:
    mtp::u64 total_ = 0;
    mtp::u64 current_ = 0;
    double last_reported_ = -1.0;
    ProgressCallback callback_ = nullptr;
    void *userdata_ = nullptr;
};

class CancellationChecker {
public:
    CancellationChecker(CancellationCallback callback, void *userdata)
        : callback_(callback), userdata_(userdata) {}

    void check() const {
        if (callback_ != nullptr && callback_(userdata_)) {
            throw mtp::OperationCancelledException();
        }
    }

private:
    CancellationCallback callback_ = nullptr;
    void *userdata_ = nullptr;
};

class FileInputStream final :
    public mtp::IObjectInputStream,
    public mtp::CancellableStream {
public:
    FileInputStream(const std::string &path, ProgressCallback callback,
                    void *progress_userdata,
                    CancellationCallback cancellation_callback,
                    void *cancellation_userdata)
        : file_(path, std::ios::binary | std::ios::ate),
          reporter_(file_size(file_, path), callback, progress_userdata),
          cancellation_(cancellation_callback, cancellation_userdata) {
        size_ = static_cast<mtp::u64>(file_.tellg());
        file_.seekg(0, std::ios::beg);
        if (!file_) {
            throw std::runtime_error("cannot seek local file: " + path);
        }
    }

    mtp::u64 GetSize() const override {
        return size_;
    }

    size_t Read(mtp::u8 *data, size_t size) override {
        cancellation_.check();
        CheckCancelled();
        file_.read(reinterpret_cast<char *>(data),
                   static_cast<std::streamsize>(size));
        const auto count = file_.gcount();
        if (file_.bad()) {
            throw std::runtime_error("failed to read local file");
        }
        reporter_.advance(static_cast<mtp::u64>(count));
        return static_cast<size_t>(count);
    }

    void finish() {
        reporter_.finish();
    }

private:
    static std::streampos file_size(std::ifstream &file,
                                    const std::string &path) {
        if (!file.is_open()) {
            throw std::runtime_error("cannot open local file: " + path);
        }
        const auto size = file.tellg();
        if (size < 0) {
            throw std::runtime_error("cannot determine local file size: " + path);
        }
        return size;
    }

    std::ifstream file_;
    mtp::u64 size_ = 0;
    ProgressReporter reporter_;
    CancellationChecker cancellation_;
};

class FileOutputStream final :
    public mtp::IObjectOutputStream,
    public mtp::CancellableStream {
public:
    FileOutputStream(const std::string &path, mtp::u64 total,
                     ProgressCallback callback, void *progress_userdata,
                     CancellationCallback cancellation_callback,
                     void *cancellation_userdata)
        : file_(path, std::ios::binary | std::ios::trunc),
          reporter_(total, callback, progress_userdata),
          cancellation_(cancellation_callback, cancellation_userdata) {
        if (!file_.is_open()) {
            throw std::runtime_error("cannot create local file: " + path);
        }
    }

    size_t Write(const mtp::u8 *data, size_t size) override {
        cancellation_.check();
        CheckCancelled();
        file_.write(reinterpret_cast<const char *>(data),
                    static_cast<std::streamsize>(size));
        if (!file_) {
            throw std::runtime_error("failed to write local file");
        }
        reporter_.advance(static_cast<mtp::u64>(size));
        return size;
    }

    void close() {
        file_.flush();
        if (!file_) {
            throw std::runtime_error("failed to flush local file");
        }
        file_.close();
    }

    void finish() {
        reporter_.finish();
    }

private:
    std::ofstream file_;
    ProgressReporter reporter_;
    CancellationChecker cancellation_;
};

} // namespace

struct AFTLSession {
    mtp::usb::ContextPtr usb_context;
    mtp::DevicePtr device;
    mtp::SessionPtr session;
    mtp::StorageId storage_id;
    mtp::ObjectId root_object_id = mtp::Session::Root;

    // A Session serializes its transactions internally. This additional lock
    // also keeps cache mutations and multi-transaction path operations atomic.
    std::recursive_mutex operation_mutex;
    std::mutex active_transfer_mutex;
    uint64_t active_transfer_id = 0;
    std::unordered_map<std::string, mtp::ObjectId> path_cache;

    // MTP exposes a storage/object hierarchy, not Android filesystem paths.
    // The app keeps this familiar path as a UI alias for the selected storage.
    const std::string root_path = "/storage/emulated/0";
};

namespace {

class ActiveTransferGuard {
public:
    ActiveTransferGuard(AFTLSession *state, uint64_t transfer_id,
                        CancellationCallback cancellation_callback,
                        void *cancellation_userdata)
        : state_(state), transfer_id_(transfer_id),
          cancellation_(cancellation_callback, cancellation_userdata) {
        if (transfer_id_ == 0) {
            throw std::invalid_argument("transfer ID must not be zero");
        }
        std::lock_guard<std::mutex> lock(state_->active_transfer_mutex);
        if (state_->active_transfer_id != 0) {
            throw std::runtime_error("another MTP transfer is already active");
        }
        state_->active_transfer_id = transfer_id_;
    }

    ~ActiveTransferGuard() {
        std::lock_guard<std::mutex> lock(state_->active_transfer_mutex);
        if (state_->active_transfer_id == transfer_id_) {
            state_->active_transfer_id = 0;
        }
    }

    ActiveTransferGuard(const ActiveTransferGuard &) = delete;
    ActiveTransferGuard &operator=(const ActiveTransferGuard &) = delete;

    void check_cancellation() const {
        cancellation_.check();
    }

private:
    AFTLSession *state_;
    uint64_t transfer_id_;
    CancellationChecker cancellation_;
};

bool relative_components(AFTLSession *state, const std::string &path,
                         std::vector<std::string> &components) {
    const std::string normalized = normalize_path(path);
    if (normalized == "/" || normalized == state->root_path) {
        components.clear();
        return true;
    }

    const std::string prefix = state->root_path + "/";
    if (normalized.compare(0, prefix.size(), prefix) != 0) {
        set_error("path is outside the selected MTP storage: " + normalized);
        return false;
    }

    components = split_path(normalized.substr(prefix.size()));
    if (std::find(components.begin(), components.end(), "..") != components.end()) {
        set_error("parent path components are not allowed");
        return false;
    }
    return true;
}

bool resolve_child(AFTLSession *state, mtp::ObjectId parent,
                   const std::string &child_name, mtp::ObjectId &result) {
    const auto handles = state->session->GetObjectHandles(
        state->storage_id, mtp::ObjectFormat::Any, parent);
    for (const auto id : handles.ObjectHandles) {
        const auto info = state->session->GetObjectInfo(id);
        if (info.Filename == child_name) {
            result = id;
            return true;
        }
    }
    return false;
}

int resolve_path_locked(AFTLSession *state, const std::string &path,
                        mtp::ObjectId &result) {
    const std::string normalized = normalize_path(path);
    const auto cached = state->path_cache.find(normalized);
    if (cached != state->path_cache.end()) {
        result = cached->second;
        return 0;
    }

    std::vector<std::string> components;
    if (!relative_components(state, normalized, components)) {
        return -2;
    }

    mtp::ObjectId current = state->root_object_id;
    std::string accumulated = state->root_path;
    for (const auto &component : components) {
        const std::string next_path = join_path(accumulated, component);
        const auto next_cached = state->path_cache.find(next_path);
        if (next_cached != state->path_cache.end()) {
            current = next_cached->second;
            accumulated = next_path;
            continue;
        }

        mtp::ObjectId child;
        if (!resolve_child(state, current, component, child)) {
            set_error("MTP object not found: " + next_path);
            return -2;
        }
        current = child;
        accumulated = next_path;
        state->path_cache[accumulated] = current;
    }

    result = current;
    return 0;
}

mtp::u64 object_size(AFTLSession *state, mtp::ObjectId object_id,
                     const mtp::msg::ObjectInfo &info) {
    if (info.ObjectCompressedSize != mtp::MaxObjectSize) {
        return info.ObjectCompressedSize;
    }
    try {
        return state->session->GetObjectIntegerProperty(
            object_id, mtp::ObjectProperty::ObjectSize);
    } catch (const std::exception &) {
        return info.ObjectCompressedSize;
    }
}

void cache_child(AFTLSession *state, mtp::ObjectId parent,
                 const std::string &name, mtp::ObjectId child) {
    std::vector<std::string> parent_paths;
    for (const auto &entry : state->path_cache) {
        if (entry.second == parent) {
            parent_paths.push_back(entry.first);
        }
    }
    for (const auto &parent_path : parent_paths) {
        state->path_cache[join_path(parent_path, name)] = child;
    }
}

void invalidate_object(AFTLSession *state, mtp::ObjectId object_id) {
    std::vector<std::string> prefixes;
    for (const auto &entry : state->path_cache) {
        if (entry.second == object_id) {
            prefixes.push_back(entry.first);
        }
    }

    for (auto iterator = state->path_cache.begin();
         iterator != state->path_cache.end();) {
        bool erase = iterator->second == object_id;
        for (const auto &prefix : prefixes) {
            if (iterator->first.compare(0, prefix.size(), prefix) == 0 &&
                (iterator->first.size() == prefix.size() ||
                 iterator->first[prefix.size()] == '/')) {
                erase = true;
                break;
            }
        }
        if (erase) {
            iterator = state->path_cache.erase(iterator);
        } else {
            ++iterator;
        }
    }
}

} // namespace

extern "C" {

const char *aftl_last_error(void) {
    return last_error.c_str();
}

AFTLSessionRef aftl_connect(void) {
    clear_error();
    auto state = std::make_unique<AFTLSession>();

    try {
        state->usb_context = std::make_shared<mtp::usb::Context>();
        state->device = mtp::Device::FindFirst(state->usb_context);
        if (!state->device) {
            set_error("no MTP device found; unlock the device and select File Transfer");
            return nullptr;
        }

        state->session = state->device->OpenSession(1);
        if (!state->session) {
            set_error("failed to open MTP session");
            return nullptr;
        }

        const auto storages = state->session->GetStorageIDs();
        if (storages.StorageIDs.empty()) {
            set_error("the MTP device exposes no storage");
            return nullptr;
        }
        state->storage_id = storages.StorageIDs.front();
        state->path_cache[state->root_path] = state->root_object_id;
        state->path_cache["/"] = state->root_object_id;

        return static_cast<AFTLSessionRef>(state.release());
    } catch (const std::exception &error) {
        set_error(std::string("connect failed: ") + error.what());
        return nullptr;
    }
}

void aftl_disconnect(AFTLSessionRef handle) {
    clear_error();
    if (!handle) {
        return;
    }
    auto *state = static_cast<AFTLSession *>(handle);
    {
        std::lock_guard<std::recursive_mutex> lock(state->operation_mutex);
        state->session.reset();
        state->device.reset();
        state->usb_context.reset();
        state->path_cache.clear();
    }
    delete state;
}

bool aftl_is_connected(AFTLSessionRef handle) {
    if (!handle) {
        return false;
    }
    auto *state = static_cast<AFTLSession *>(handle);
    std::lock_guard<std::recursive_mutex> lock(state->operation_mutex);
    return state->session != nullptr;
}

AFTLDeviceInfo aftl_get_device_info(AFTLSessionRef handle) {
    clear_error();
    AFTLDeviceInfo result = {};
    if (!handle) {
        set_error("device is not connected");
        return result;
    }
    auto *state = static_cast<AFTLSession *>(handle);
    std::lock_guard<std::recursive_mutex> lock(state->operation_mutex);

    try {
        const auto &device_info = state->session->GetDeviceInfo();
        result.manufacturer = duplicate_string(device_info.Manufacturer);
        result.model = duplicate_string(device_info.Model);
        result.serial = duplicate_string(device_info.SerialNumber);
        if (!result.manufacturer || !result.model || !result.serial) {
            throw std::bad_alloc();
        }

        const auto storage_info = state->session->GetStorageInfo(state->storage_id);
        result.storage_total = storage_info.MaxCapacity;
        result.storage_free = storage_info.FreeSpaceInBytes;

        char description[128];
        std::snprintf(description, sizeof(description), "%.1f GB, %.1f GB free",
                      result.storage_total / 1073741824.0,
                      result.storage_free / 1073741824.0);
        result.storage_description = duplicate_string(description);
        if (!result.storage_description) {
            throw std::bad_alloc();
        }
    } catch (const std::exception &error) {
        set_error(std::string("get device info failed: ") + error.what());
    }
    return result;
}

void aftl_free_device_info(AFTLDeviceInfo *info) {
    if (!info) {
        return;
    }
    std::free(info->manufacturer);
    std::free(info->model);
    std::free(info->serial);
    std::free(info->storage_description);
    *info = {};
}

int aftl_resolve_path(AFTLSessionRef handle, const char *path,
                      uint32_t *object_id) {
    clear_error();
    if (!handle || !path || !object_id) {
        set_error("invalid path resolution arguments");
        return -1;
    }
    auto *state = static_cast<AFTLSession *>(handle);
    std::lock_guard<std::recursive_mutex> lock(state->operation_mutex);

    try {
        mtp::ObjectId resolved;
        const int result = resolve_path_locked(state, path, resolved);
        if (result == 0) {
            *object_id = resolved.Id;
        }
        return result;
    } catch (const std::exception &error) {
        set_error(std::string("resolve path failed: ") + error.what());
        return -3;
    }
}

uint32_t aftl_get_root_object_id(AFTLSessionRef handle) {
    if (!handle) {
        return 0;
    }
    return static_cast<AFTLSession *>(handle)->root_object_id.Id;
}

int aftl_list_files(AFTLSessionRef handle, const char *path,
                    AFTLFileList *out) {
    clear_error();
    if (out) {
        *out = {};
    }
    if (!handle || !path || !out) {
        set_error("invalid list arguments");
        return -1;
    }
    auto *state = static_cast<AFTLSession *>(handle);
    std::lock_guard<std::recursive_mutex> lock(state->operation_mutex);
    std::vector<AFTLFileInfo> files;

    try {
        mtp::ObjectId parent_id;
        if (resolve_path_locked(state, path, parent_id) != 0) {
            return -2;
        }

        const auto handles = state->session->GetObjectHandles(
            state->storage_id, mtp::ObjectFormat::Any, parent_id);
        files.reserve(handles.ObjectHandles.size());
        const std::string normalized_parent = normalize_path(path);

        for (const auto id : handles.ObjectHandles) {
            const auto info = state->session->GetObjectInfo(id);
            AFTLFileInfo file = {};
            file.object_id = id.Id;
            file.name = duplicate_string(info.Filename);
            if (!file.name) {
                throw std::bad_alloc();
            }
            file.is_directory = info.ObjectFormat == mtp::ObjectFormat::Association;
            file.size = file.is_directory ? 0 : object_size(state, id, info);
            files.push_back(file);
            state->path_cache[join_path(normalized_parent, info.Filename)] = id;
        }

        if (!files.empty()) {
            out->items = static_cast<AFTLFileInfo *>(
                std::malloc(sizeof(AFTLFileInfo) * files.size()));
            if (!out->items) {
                throw std::bad_alloc();
            }
            std::memcpy(out->items, files.data(),
                        sizeof(AFTLFileInfo) * files.size());
        }
        out->count = static_cast<int>(files.size());
        return 0;
    } catch (const std::exception &error) {
        for (auto &file : files) {
            std::free(file.name);
            file.name = nullptr;
        }
        set_error(std::string("list files failed: ") + error.what());
        return -3;
    }
}

void aftl_free_file_list(AFTLFileList *list) {
    if (!list) {
        return;
    }
    for (int index = 0; index < list->count; ++index) {
        std::free(list->items[index].name);
    }
    std::free(list->items);
    *list = {};
}

int aftl_cancel_transfer(AFTLSessionRef handle, uint64_t transfer_id) {
    if (!handle || transfer_id == 0) {
        return -1;
    }
    auto *state = static_cast<AFTLSession *>(handle);

    // A transfer may have published its ID a fraction before Session creates
    // the transaction. Retry briefly, but always compare the ID under the same
    // mutex used by the transfer guard so a late cancellation cannot abort the
    // following queued transfer.
    for (int attempt = 0; attempt < 100; ++attempt) {
        std::unique_lock<std::mutex> lock(state->active_transfer_mutex);
        if (state->active_transfer_id != transfer_id) {
            return 1;
        }
        try {
            state->session->AbortCurrentTransaction(1000);
            return 0;
        } catch (const std::exception &) {
            lock.unlock();
            std::this_thread::sleep_for(std::chrono::milliseconds(2));
        }
    }
    return -2;
}

int aftl_download(AFTLSessionRef handle, uint32_t object_id,
                  const char *local_path, ProgressCallback progress_cb,
                  void *progress_userdata,
                  CancellationCallback cancellation_cb,
                  void *cancellation_userdata, uint64_t transfer_id) {
    clear_error();
    if (!handle || object_id == 0 || !local_path) {
        set_error("invalid download arguments");
        return -1;
    }
    auto *state = static_cast<AFTLSession *>(handle);
    std::lock_guard<std::recursive_mutex> lock(state->operation_mutex);
    const std::string destination(local_path);
    const std::string partial_path = destination + ".nextaft-part";
    std::remove(partial_path.c_str());

    try {
        ActiveTransferGuard transfer(state, transfer_id, cancellation_cb,
                                     cancellation_userdata);
        transfer.check_cancellation();
        const mtp::ObjectId id(object_id);
        const auto info = state->session->GetObjectInfo(id);
        if (info.ObjectFormat == mtp::ObjectFormat::Association) {
            throw std::runtime_error("cannot download a directory as a file");
        }

        auto stream = std::make_shared<FileOutputStream>(
            partial_path, object_size(state, id, info), progress_cb,
            progress_userdata, cancellation_cb, cancellation_userdata);
        transfer.check_cancellation();
        state->session->GetObject(id, stream);
        stream->close();

        if (std::rename(partial_path.c_str(), destination.c_str()) != 0) {
            throw std::runtime_error(std::string("cannot replace destination file: ") +
                                     std::strerror(errno));
        }
        stream->finish();
        return 0;
    } catch (const mtp::OperationCancelledException &) {
        std::remove(partial_path.c_str());
        set_error("download cancelled");
        return -4;
    } catch (const std::exception &error) {
        std::remove(partial_path.c_str());
        set_error(std::string("download failed: ") + error.what());
        return -3;
    }
}

int aftl_upload(AFTLSessionRef handle, const char *local_path,
                const char *remote_name, uint32_t parent_object_id,
                ProgressCallback progress_cb, void *progress_userdata,
                CancellationCallback cancellation_cb,
                void *cancellation_userdata, uint64_t transfer_id,
                uint32_t *new_object_id) {
    clear_error();
    if (new_object_id) {
        *new_object_id = 0;
    }
    if (!handle || !local_path || !remote_name || remote_name[0] == '\0') {
        set_error("invalid upload arguments");
        return -1;
    }
    auto *state = static_cast<AFTLSession *>(handle);
    std::lock_guard<std::recursive_mutex> lock(state->operation_mutex);
    mtp::ObjectId created_id;
    bool created = false;

    try {
        ActiveTransferGuard transfer(state, transfer_id, cancellation_cb,
                                     cancellation_userdata);
        transfer.check_cancellation();
        auto stream = std::make_shared<FileInputStream>(local_path,
                                                       progress_cb,
                                                       progress_userdata,
                                                       cancellation_cb,
                                                       cancellation_userdata);
        mtp::msg::ObjectInfo object_info;
        object_info.Filename = remote_name;
        object_info.ObjectFormat = mtp::ObjectFormatFromFilename(remote_name);
        object_info.ObjectCompressedSize = stream->GetSize();

        const mtp::ObjectId parent(parent_object_id);
        const auto result = state->session->SendObjectInfo(
            object_info, state->storage_id, parent);
        created_id = result.ObjectId;
        created = true;
        transfer.check_cancellation();
        state->session->SendObject(stream);
        stream->finish();
        cache_child(state, parent, remote_name, created_id);

        if (new_object_id) {
            *new_object_id = created_id.Id;
        }
        return 0;
    } catch (const mtp::OperationCancelledException &) {
        if (created) {
            try {
                state->session->DeleteObject(created_id);
            } catch (const std::exception &) {
                // The transfer remains cancelled even if cleanup fails.
            }
        }
        set_error("upload cancelled");
        return -4;
    } catch (const std::exception &error) {
        if (created) {
            try {
                state->session->DeleteObject(created_id);
            } catch (const std::exception &) {
                // Preserve the original upload error.
            }
        }
        set_error(std::string("upload failed: ") + error.what());
        return -3;
    }
}

int aftl_delete(AFTLSessionRef handle, uint32_t object_id) {
    clear_error();
    if (!handle || object_id == 0 ||
        object_id == mtp::Session::Root.Id) {
        set_error("invalid delete arguments");
        return -1;
    }
    auto *state = static_cast<AFTLSession *>(handle);
    std::lock_guard<std::recursive_mutex> lock(state->operation_mutex);

    try {
        const mtp::ObjectId id(object_id);
        state->session->DeleteObject(id);
        invalidate_object(state, id);
        return 0;
    } catch (const std::exception &error) {
        set_error(std::string("delete failed: ") + error.what());
        return -2;
    }
}

int aftl_mkdir(AFTLSessionRef handle, const char *name,
               uint32_t parent_object_id, uint32_t *new_dir_id) {
    clear_error();
    if (new_dir_id) {
        *new_dir_id = 0;
    }
    if (!handle || !name || name[0] == '\0') {
        set_error("invalid create-directory arguments");
        return -1;
    }
    auto *state = static_cast<AFTLSession *>(handle);
    std::lock_guard<std::recursive_mutex> lock(state->operation_mutex);

    try {
        const mtp::ObjectId parent(parent_object_id);
        const auto result = state->session->CreateDirectory(
            name, parent, state->storage_id);
        cache_child(state, parent, name, result.ObjectId);
        if (new_dir_id) {
            *new_dir_id = result.ObjectId.Id;
        }
        return 0;
    } catch (const std::exception &error) {
        set_error(std::string("create directory failed: ") + error.what());
        return -2;
    }
}

} // extern "C"
