// MotionForge core — collaborative editing: a project as small keyed pieces that sync on their own.
//
//   comp/<c>             a composition's settings (no layers)
//   layer/<c>/<l>        a layer without its properties, plus "z", its place in the stack
//   prop/<c>/<l>/<key>   one property of that layer (value and keyframes)
//   asset/<a>            media: kind, name, size, duration and "media", the file's content name (sha256.ext)
//
// A piece's value is compact JSON; an empty value means deleted. Each piece carries a Lamport clock
// and the id of the Mac that wrote it; the higher (clock, client) wins, so every Mac ends up with the
// same project whatever order edits arrive in. People editing different layers, or different
// properties of one layer, never overwrite each other. Stack order is a fractional "z" per layer,
// so adding and reordering layers at the same time doesn't clash.
//
// Undo is per person: it reverts the pieces your own step changed, unless someone has changed them
// since (then their edit stands). What each Mac views (active composition) isn't shared.
#pragma once

#include <cstdint>
#include <functional>
#include <map>
#include <set>
#include <string>
#include <vector>

#include "mf/Model.hpp"

namespace mf {

struct SyncPiece {
    std::string key;
    std::string value;  // compact JSON; empty = deleted
    int64_t clock = 0;
    std::string client;
    bool deleted() const { return value.empty(); }
    // (clock, client) ordering: true when this piece should replace `o`.
    bool newerThan(const SyncPiece& o) const { return clock != o.clock ? clock > o.clock : client > o.client; }
};

// Wire format shared with the server and the live channel:
// [{"k": key, "v": value JSON or null, "c": clock, "n": client}, …]
std::string piecesToJson(const std::vector<SyncPiece>& pieces);
bool piecesFromJson(const std::string& text, std::vector<SyncPiece>& out, std::string& error);

// Ids of objects created by collaborator `slot` start at slot << 40, so two Macs never allocate the
// same id. Slot 0 is the range a project had before it was shared.
inline constexpr int kSyncSlotShift = 40;
inline ObjectId syncIdBase(int slot) { return ObjectId(slot) << kSyncSlotShift; }

class SyncEngine {
public:
    explicit SyncEngine(std::string clientId);

    // The media name ("<sha256>.<ext>") for an asset's file; "" if it can't be read.
    std::function<std::string(const Asset&)> mediaNameForAsset;
    // Where a media file is (or will be) on this Mac; it may not exist yet.
    std::function<std::string(const std::string& media)> pathForMedia;

    // Sharing an existing project: every piece of it, to seed the server.
    std::vector<SyncPiece> start(const Project& p);
    // Joining: builds the project from the server's pieces. `view` keeps this Mac's active composition.
    Project join(const std::vector<SyncPiece>& pieces, const Project& view);

    // After local edits: the pieces that changed since the last call. `newStep` starts a new undo step
    // (otherwise the changes join the current one, e.g. during a drag).
    std::vector<SyncPiece> collectLocal(const Project& now, bool newStep);

    // Pieces from others (live or from the server). Newer ones are applied to `project`.
    // Returns true when the project changed.
    bool applyRemote(const std::vector<SyncPiece>& pieces, Project& project);

    bool canUndo() const { return !undo_.empty(); }
    bool canRedo() const { return !redo_.empty(); }
    // Reverts / re-applies your last step in `project`; returns the pieces to send.
    std::vector<SyncPiece> undo(Project& project);
    std::vector<SyncPiece> redo(Project& project);

    // Media finished downloading: point assets at their files again. Returns true if any changed.
    bool refreshMedia(Project& project);

    const std::string& client() const { return client_; }
    int64_t clock() const { return clock_; }
    size_t pieceCount() const { return shadow_.size(); }
    const SyncPiece* piece(const std::string& key) const;

private:
    struct Step {
        std::map<std::string, std::pair<std::string, std::string>> changes;  // key → (before, after)
    };
    using PieceMap = std::map<std::string, std::string>;  // key → value

    PieceMap explode(const Project& p, const Project* previous, const std::set<std::string>* onlyLayers);
    std::vector<SyncPiece> writeLocal(const PieceMap& values, bool newStep, bool recordUndo);
    bool rebuild(const std::set<std::string>& keys, Project& project);
    void assignZ(const Composition& c, PieceMap& out);
    std::vector<SyncPiece> revert(std::vector<Step>& from, std::vector<Step>& to, Project& project);

    std::string client_;
    int64_t clock_ = 0;
    std::map<std::string, SyncPiece> shadow_;  // the agreed state, tombstones included
    Project last_;                             // the project as of the last sync, for diffs
    std::map<ObjectId, double> z_;             // layer id → stack position
    std::vector<Step> undo_, redo_;
    bool stepOpen_ = false;
};

}  // namespace mf
