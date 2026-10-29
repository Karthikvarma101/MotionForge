// MotionForge core — editing commands for Claude: one catalog of tools (name, description, JSON
// Schema of the input) and one entry point that runs a tool on a Document.
//
// The same catalog backs the MCP server (Claude Desktop / Claude Code drive the open editor) and
// the in-app Claude panel. Every tool call that changes the project is one undo step labelled
// "Claude: <tool>". Layers can be named by id or by name; compositions default to the active one.
//
// Tools whose `scope` is "host" need the renderer or the app (rendering a frame, importing media,
// saving, exporting): runTool() answers them with `handled = false` and the caller runs them.
#pragma once

#include <string>
#include <vector>

#include "mf/Document.hpp"
#include "mf/Json.hpp"

namespace mf {

struct ToolDef {
    std::string name;
    std::string description;
    Json inputSchema;   // JSON Schema (type: object)
    bool host = false;  // run by the renderer / app, not by runTool()
};

// All tools, in the order they are offered to Claude.
const std::vector<ToolDef>& toolCatalog();
const ToolDef* findTool(const std::string& name);

struct ToolResult {
    bool handled = true;  // false: a host tool, run it elsewhere
    bool ok = true;
    Json value;           // the answer (object) when ok
    std::string error;    // what went wrong, phrased for Claude, when !ok
};

ToolResult runTool(Document& doc, const std::string& name, const Json& args);

// Helpers shared with host tools.
// `ref` is a number (id) or a string (name, case-insensitive). 0 when not found.
ObjectId resolveComposition(const Project& p, const Json& ref);
ObjectId resolveLayer(const Composition& c, const Json& ref);
// Number, [x, y, …], {"x":…,"y":…} or "#RRGGBB(AA)" (colours) → Value; false if unusable.
bool valueFromArgument(const Json& j, int dims, bool isColor, Value& out);

}  // namespace mf
