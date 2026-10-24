#include <IExtensionSys.h>
#include <sp_vm_api.h>
#include <ISourceMod.h>
#include <sys/stat.h>
#include <sys/file.h>
#include <fcntl.h>
#include <unistd.h>
#include <cstdint>
#include <cmath>
#include <cstdio>
#include <cerrno>

using namespace SourceMod;
using namespace SourcePawn;

static ISourceMod* sourceMod = nullptr;

// FileType values match SourceMod, with 3 reserved for a symbolic link.
// lstat inspects the directory entry itself rather than following its target.
static cell_t ReplayPathType(IPluginContext* context, const cell_t* params)
{
    char* path = nullptr;
    if (context->LocalToString(params[1], &path) != SP_ERROR_NONE || path == nullptr) return 0;
    char absolute[4096];
    sourceMod->BuildPath(Path_Game, absolute, sizeof(absolute), "%s", path);
    struct stat info;
    if (lstat(absolute, &info) != 0) return 0;
    if (S_ISLNK(info.st_mode)) return 3;
    if (S_ISDIR(info.st_mode)) return 1;
    if (S_ISREG(info.st_mode)) return 2;
    return 0;
}


static bool GamePath(IPluginContext* context, cell_t address, char* output, size_t length)
{
    char* path = nullptr;
    if (context->LocalToString(address, &path) != SP_ERROR_NONE || path == nullptr) return false;
    sourceMod->BuildPath(Path_Game, output, length, "%s", path);
    return true;
}

static cell_t ReplayRevision(IPluginContext* context, const cell_t* params)
{
    char path[4096], revision[192];
    struct stat info;
    if (!GamePath(context, params[1], path, sizeof(path)) || lstat(path, &info) != 0 || !S_ISREG(info.st_mode)) return false;
    snprintf(revision, sizeof(revision), "%lld:%ld:%lld:%lld:%lld:%ld",
        static_cast<long long>(info.st_mtim.tv_sec), info.st_mtim.tv_nsec,
        static_cast<long long>(info.st_size), static_cast<long long>(info.st_ino),
        static_cast<long long>(info.st_ctim.tv_sec), info.st_ctim.tv_nsec);
    return context->StringToLocal(params[2], params[3], revision) == SP_ERROR_NONE;
}

static cell_t SnapshotReplay(IPluginContext* context, const cell_t* params)
{
    char source[4096], destination[4096];
    if (!GamePath(context, params[1], source, sizeof(source)) || !GamePath(context, params[2], destination, sizeof(destination))) return false;
    int input = open(source, O_RDONLY | O_NOFOLLOW | O_NONBLOCK);
    if (input < 0) return false;
    struct stat before{}, after{};
    bool valid = fstat(input, &before) == 0 && S_ISREG(before.st_mode) && before.st_size > 0 && before.st_size <= 16 * 1024 * 1024;
    int output = valid ? open(destination, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0600) : -1;
    if (output < 0) { close(input); return false; }
    uint32_t hash = 0xffffffffU;
    char buffer[8192];
    ssize_t total = 0, count;
    while (valid && (count = read(input, buffer, sizeof(buffer))) != 0)
    {
        if (count < 0) { if (errno == EINTR) continue; valid = false; break; }
        total += count;
        if (total > before.st_size) { valid = false; break; }
        for (ssize_t i = 0; i < count; i++)
        {
            hash ^= static_cast<unsigned char>(buffer[i]);
            for (int bit = 0; bit < 8; bit++) hash = (hash >> 1) ^ ((hash & 1) ? 0xedb88320U : 0);
        }
        ssize_t written = 0;
        while (written < count)
        {
            ssize_t n = write(output, buffer + written, count - written);
            if (n < 0 && errno == EINTR) continue;
            if (n <= 0) { valid = false; break; }
            written += n;
        }
    }
    valid = valid && total == before.st_size && fstat(input, &after) == 0
        && before.st_size == after.st_size
        && before.st_mtim.tv_sec == after.st_mtim.tv_sec && before.st_mtim.tv_nsec == after.st_mtim.tv_nsec
        && before.st_ctim.tv_sec == after.st_ctim.tv_sec && before.st_ctim.tv_nsec == after.st_ctim.tv_nsec;
    close(input);
    if (close(output) != 0) valid = false;
    if (!valid) { unlink(destination); return false; }
    cell_t* checksum = nullptr;
    if (context->LocalToPhysAddr(params[3], &checksum) != SP_ERROR_NONE) { unlink(destination); return false; }
    *checksum = static_cast<cell_t>(hash);
    return true;
}


// B's game instances share a SourceMod directory. A process-held file lock
// prevents concurrent scanners, candidate files, and HTTP workers across them.
static int workerLock = -1;
static cell_t ReplayWorkerLock(IPluginContext* context, const cell_t* params)
{
    if (workerLock >= 0) return true;
    char path[4096];
    if (!GamePath(context, params[1], path, sizeof(path))) return false;
    int fd = open(path, O_RDWR | O_CREAT | O_NOFOLLOW, 0600);
    if (fd < 0) return false;
    if (flock(fd, LOCK_EX | LOCK_NB) != 0) { close(fd); return false; }
    workerLock = fd;
    return true;
}
static cell_t ReplayReleaseWorker(IPluginContext*, const cell_t*)
{
    if (workerLock >= 0) { close(workerLock); workerLock = -1; }
    return 0;
}


// Match the backend's four-decimal ROUND_HALF_UP conversion exactly.
static cell_t FormatJumpDistance(IPluginContext* context, const cell_t* params)
{
    double value = sp_ctof(params[1]);
    if (!std::isfinite(value) || value <= 0 || value >= 100000) return false;
    int64_t units = static_cast<int64_t>(value * 10000.0 + 0.5);
    char text[32];
    snprintf(text, sizeof(text), "%lld.%04lld", static_cast<long long>(units / 10000), static_cast<long long>(units % 10000));
    return context->StringToLocal(params[2], params[3], text) == SP_ERROR_NONE;
}

static const sp_nativeinfo_t natives[] = {
    {"GOKZTop_ReplayPathType", ReplayPathType},
    {"GOKZTop_FormatJumpDistance", FormatJumpDistance},
    {"GOKZTop_ReplayWorkerLock", ReplayWorkerLock},
    {"GOKZTop_ReplayReleaseWorker", ReplayReleaseWorker},
    {"GOKZTop_ReplayRevision", ReplayRevision},
    {"GOKZTop_SnapshotReplay", SnapshotReplay},
    {nullptr, nullptr}
};

class ReplayFilesystem final : public IExtensionInterface
{
public:
    bool OnExtensionLoad(IExtension* me, IShareSys* sys, char*, size_t, bool) override
    {
        if (!sys->RequestInterface(SMINTERFACE_SOURCEMOD_NAME, SMINTERFACE_SOURCEMOD_VERSION, me, reinterpret_cast<SMInterface**>(&sourceMod))) return false;
        sys->AddNatives(me, natives);
        return true;
    }
    void OnExtensionUnload() override { ReplayReleaseWorker(nullptr, nullptr); }
    void OnExtensionsAllLoaded() override {}
    void OnExtensionPauseChange(bool) override {}
    bool IsMetamodExtension() override { return false; }
    const char* GetExtensionName() override { return "GOKZ Top Replay Filesystem"; }
    const char* GetExtensionURL() override { return "https://gokz.top"; }
    const char* GetExtensionTag() override { return "GOKZTOP"; }
    const char* GetExtensionAuthor() override { return "KZCharm"; }
    const char* GetExtensionVerString() override { return "0.2.1"; }
    const char* GetExtensionDescription() override { return "Filesystem entry inspection without following symbolic links"; }
    const char* GetExtensionDateString() override { return __DATE__; }
};

static ReplayFilesystem extension;
extern "C" __attribute__((visibility("default"))) IExtensionInterface* GetSMExtAPI()
{
    return &extension;
}
