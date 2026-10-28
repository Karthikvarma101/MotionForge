// MotionForge core — byte-budgeted LRU cache. Header-only so the Objective-C++ renderer can
// store `id<MTLTexture>` values in it under ARC, while the policy stays unit-testable in C++.
#pragma once

#include <cstddef>
#include <cstdint>
#include <functional>
#include <list>
#include <optional>
#include <unordered_map>
#include <utility>

namespace mf {

template <typename Key, typename Value>
class LruCache {
public:
    // Called for every value that leaves the cache (eviction, purge, replacement), so the owner
    // can recycle the resource (e.g. return a texture to a pool) instead of freeing it.
    using EvictFn = std::function<void(const Key&, Value&&, size_t bytes)>;

    explicit LruCache(size_t budgetBytes = 0, EvictFn onEvict = {}) : budget_(budgetBytes), onEvict_(std::move(onEvict)) {}

    void setEvictionHandler(EvictFn fn) { onEvict_ = std::move(fn); }
    void setBudget(size_t bytes) {
        budget_ = bytes;
        trim();
    }
    size_t budget() const { return budget_; }
    size_t bytes() const { return bytes_; }
    size_t size() const { return map_.size(); }
    uint64_t hits() const { return hits_; }
    uint64_t misses() const { return misses_; }
    void resetStats() { hits_ = misses_ = 0; }

    // Returns a pointer valid until the next mutating call; marks the entry most-recently-used.
    Value* find(const Key& k) {
        auto it = map_.find(k);
        if (it == map_.end()) {
            ++misses_;
            return nullptr;
        }
        ++hits_;
        order_.splice(order_.begin(), order_, it->second);
        return &it->second->value;
    }
    bool contains(const Key& k) const { return map_.count(k) != 0; }

    // Inserts (or replaces) an entry. Entries larger than the whole budget are rejected
    // (handed straight to the eviction handler) so one huge frame can't flush everything.
    bool insert(const Key& k, Value v, size_t bytes) {
        erase(k);
        if (bytes > budget_) {
            if (onEvict_) onEvict_(k, std::move(v), bytes);
            return false;
        }
        order_.push_front(Entry{k, std::move(v), bytes});
        map_[k] = order_.begin();
        bytes_ += bytes;
        trim();
        return true;
    }

    bool erase(const Key& k) {
        auto it = map_.find(k);
        if (it == map_.end()) return false;
        evict(it->second);
        return true;
    }

    // Drops entries (oldest first) until at most `targetBytes` remain.
    void purgeTo(size_t targetBytes) {
        while (bytes_ > targetBytes && !order_.empty()) evict(std::prev(order_.end()));
    }
    void clear() { purgeTo(0); }

private:
    struct Entry {
        Key key;
        Value value;
        size_t bytes;
    };
    using Iter = typename std::list<Entry>::iterator;

    void trim() { purgeTo(budget_); }
    void evict(Iter it) {
        bytes_ -= it->bytes;
        map_.erase(it->key);
        Entry e = std::move(*it);
        order_.erase(it);
        if (onEvict_) onEvict_(e.key, std::move(e.value), e.bytes);
    }

    size_t budget_ = 0;
    size_t bytes_ = 0;
    uint64_t hits_ = 0, misses_ = 0;
    std::list<Entry> order_;  // front = most recently used
    std::unordered_map<Key, Iter> map_;
    EvictFn onEvict_;
};

}  // namespace mf
