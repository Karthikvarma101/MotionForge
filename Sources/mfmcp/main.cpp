// mfmcp — MotionForge's MCP server for Claude Desktop and Claude Code (stdio transport).
//
// It answers `initialize` and `ping` itself and forwards `tools/list` and `tools/call` to the
// running MotionForge app over its owner-only Unix socket
// (~/Library/Application Support/MotionForge/claude.sock), starting the app when it isn't open.
// Edits therefore happen live in the editor, with undo. It lives in MotionForge.app/Contents/MacOS.
//
//   claude mcp add motionforge -- /Applications/MotionForge.app/Contents/MacOS/mfmcp
#include <mach-o/dyld.h>
#include <spawn.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>

#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <iostream>
#include <string>
#include <thread>

#include "mf/Commands.hpp"
#include "mf/Json.hpp"

extern char** environ;

using mf::Json;

namespace {

constexpr const char* kVersion = "0.3.0";
constexpr const char* kInstructions =
    "Tools for MotionForge, the motion graphics editor open on this Mac. Changes appear live in the editor and "
    "each tool call is one undo step. Start with get_project / get_composition, use layer ids from their answers, "
    "and check your work with render_frame. Times are seconds; positions are composition pixels from the top-left; "
    "colours are [r,g,b,a] 0-1 or \"#RRGGBB\".";

std::string socketPath() {
    if (const char* p = std::getenv("MOTIONFORGE_CLAUDE_SOCKET")) return p;
    const char* home = std::getenv("HOME");
    return std::string(home ? home : "") + "/Library/Application Support/MotionForge/claude.sock";
}

void send(const Json& message) {
    std::string line = message.dump(0);
    line.push_back('\n');
    std::fwrite(line.data(), 1, line.size(), stdout);
    std::fflush(stdout);
}

Json reply(const Json& id, Json result) {
    Json r = Json::object();
    r.set("jsonrpc", Json("2.0"));
    r.set("id", id);
    r.set("result", std::move(result));
    return r;
}

Json errorReply(const Json& id, int code, const std::string& message) {
    Json e = Json::object();
    e.set("code", Json(code));
    e.set("message", Json(message));
    Json r = Json::object();
    r.set("jsonrpc", Json("2.0"));
    r.set("id", id);
    r.set("error", std::move(e));
    return r;
}

Json toolError(const std::string& text) {
    Json c = Json::object();
    c.set("type", Json("text"));
    c.set("text", Json(text));
    Json content = Json::array();
    content.push(std::move(c));
    Json r = Json::object();
    r.set("content", std::move(content));
    r.set("isError", Json(true));
    return r;
}

// ---- the app connection -----------------------------------------------------------------------

class AppLink {
public:
    ~AppLink() { closeLink(); }

    // Sends one request and waits for the answer with the same id. Starts the app if needed.
    bool call(const Json& request, Json& answer, std::string& error, bool launch) {
        for (int attempt = 0; attempt < 2; ++attempt) {
            if (fd_ < 0 && !connectOrLaunch(launch, error)) return false;
            if (exchange(request, answer)) return true;
            closeLink();  // the app quit or restarted: reconnect once
        }
        error = "Lost the connection to MotionForge.";
        return false;
    }

private:
    int fd_ = -1;
    std::string pending_;

    void closeLink() {
        if (fd_ >= 0) close(fd_);
        fd_ = -1;
        pending_.clear();
    }

    bool tryConnect() {
        const std::string path = socketPath();
        sockaddr_un addr{};
        addr.sun_family = AF_UNIX;
        if (path.size() >= sizeof(addr.sun_path)) return false;
        std::memcpy(addr.sun_path, path.c_str(), path.size() + 1);
        const int fd = socket(AF_UNIX, SOCK_STREAM, 0);
        if (fd < 0) return false;
        int on = 1;
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, sizeof on);
        if (connect(fd, reinterpret_cast<sockaddr*>(&addr), sizeof addr) != 0) {
            close(fd);
            return false;
        }
        fd_ = fd;
        return true;
    }

    // The app this helper is inside (…/MotionForge.app), else whatever app has the bundle id.
    static void launchApp() {
        char exe[4096];
        uint32_t size = sizeof exe;
        std::string app;
        if (_NSGetExecutablePath(exe, &size) == 0) {
            const std::string p(exe);
            const size_t at = p.find(".app/Contents/MacOS/");
            if (at != std::string::npos) app = p.substr(0, at + 4);
        }
        std::string a1 = "-a", a2 = app, b1 = "-b", b2 = "com.motionforge.MotionForge";
        char* argvApp[] = {const_cast<char*>("/usr/bin/open"), a1.data(), a2.data(), nullptr};
        char* argvId[] = {const_cast<char*>("/usr/bin/open"), b1.data(), b2.data(), nullptr};
        pid_t pid;
        posix_spawn(&pid, "/usr/bin/open", nullptr, nullptr, app.empty() ? argvId : argvApp, environ);
    }

    bool connectOrLaunch(bool launch, std::string& error) {
        if (tryConnect()) return true;
        if (!launch) {
            error = "MotionForge isn't running.";
            return false;
        }
        std::fprintf(stderr, "mfmcp: starting MotionForge\n");
        launchApp();
        for (int i = 0; i < 300; ++i) {  // up to 30 s: first launch shows the app's opening animation
            std::this_thread::sleep_for(std::chrono::milliseconds(100));
            if (tryConnect()) return true;
        }
        error = "Couldn't start MotionForge (or it didn't answer within 30 seconds). Open MotionForge and try again.";
        return false;
    }

    bool exchange(const Json& request, Json& answer) {
        std::string line = request.dump(0);
        line.push_back('\n');
        size_t off = 0;
        while (off < line.size()) {
            const ssize_t w = write(fd_, line.data() + off, line.size() - off);
            if (w <= 0) return false;
            off += size_t(w);
        }
        const double wanted = request.get("id").number(-1);
        char buf[65536];
        for (;;) {
            size_t nl;
            while ((nl = pending_.find('\n')) != std::string::npos) {
                const std::string msg = pending_.substr(0, nl);
                pending_.erase(0, nl + 1);
                Json j;
                std::string err;
                if (Json::parse(msg, j, err) && j.get("id").number(-2) == wanted) {
                    answer = std::move(j);
                    return true;
                }
            }
            const ssize_t n = read(fd_, buf, sizeof buf);
            if (n <= 0) return false;
            pending_.append(buf, size_t(n));
        }
    }
};

Json offlineToolList() {
    Json tools = Json::array();
    for (const mf::ToolDef& t : mf::toolCatalog()) {
        Json j = Json::object();
        j.set("name", Json(t.name));
        j.set("description", Json(t.description));
        j.set("inputSchema", t.inputSchema);
        tools.push(std::move(j));
    }
    Json r = Json::object();
    r.set("tools", std::move(tools));
    return r;
}

}  // namespace

int main(int argc, char** argv) {
    if (argc > 1 && (std::strcmp(argv[1], "--version") == 0 || std::strcmp(argv[1], "-v") == 0)) {
        std::printf("mfmcp %s (MotionForge MCP server, %zu tools)\n", kVersion, mf::toolCatalog().size());
        return 0;
    }
    AppLink app;
    double nextId = 1;
    std::string line;
    while (std::getline(std::cin, line)) {
        if (line.empty()) continue;
        Json msg;
        std::string perr;
        if (!Json::parse(line, msg, perr)) {
            send(errorReply(Json(), -32700, "Parse error: " + perr));
            continue;
        }
        const std::string method = msg.get("method").string();
        if (!msg.has("id")) continue;  // notifications (initialized, cancelled…) need no answer
        const Json& id = msg.get("id");

        if (method == "initialize") {
            const std::string asked = msg.get("params").get("protocolVersion").string();
            const char* supported[] = {"2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"};
            std::string version = "2025-06-18";
            for (const char* v : supported)
                if (asked == v) version = v;
            Json caps = Json::object();
            caps.set("tools", Json::object());
            Json info = Json::object();
            info.set("name", Json("motionforge"));
            info.set("title", Json("MotionForge"));
            info.set("version", Json(kVersion));
            Json r = Json::object();
            r.set("protocolVersion", Json(version));
            r.set("capabilities", std::move(caps));
            r.set("serverInfo", std::move(info));
            r.set("instructions", Json(kInstructions));
            send(reply(id, std::move(r)));
        } else if (method == "ping") {
            send(reply(id, Json::object()));
        } else if (method == "tools/list" || method == "tools/call") {
            Json forward = Json::object();
            forward.set("id", Json(nextId++));
            forward.set("method", Json(method));
            forward.set("params", msg.get("params"));
            Json answer;
            std::string error;
            // Listing doesn't start the app (Claude lists tools when it starts); calling does.
            if (app.call(forward, answer, error, method == "tools/call")) {
                if (answer.has("error")) send(errorReply(id, int(answer.get("error").get("code").number(-32603)),
                                                         answer.get("error").get("message").string()));
                else send(reply(id, answer.get("result")));
            } else if (method == "tools/list") {
                send(reply(id, offlineToolList()));
            } else {
                send(reply(id, toolError(error)));
            }
        } else {
            send(errorReply(id, -32601, "Method not found: " + method));
        }
    }
    return 0;
}
