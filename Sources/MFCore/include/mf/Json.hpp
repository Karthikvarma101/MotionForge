// MotionForge core — small dependency-free JSON value, parser and writer for project files.
#pragma once

#include <cstdint>
#include <map>
#include <memory>
#include <string>
#include <string_view>
#include <utility>
#include <vector>

namespace mf {

class Json {
public:
    enum class Type : uint8_t { Null, Bool, Number, String, Array, Object };
    using Array = std::vector<Json>;
    using Object = std::vector<std::pair<std::string, Json>>;  // keeps insertion order

    Json() = default;
    Json(std::nullptr_t) {}
    Json(bool b) : type_(Type::Bool), bool_(b) {}
    Json(double n) : type_(Type::Number), num_(n) {}
    Json(int n) : type_(Type::Number), num_(n) {}
    Json(int64_t n) : type_(Type::Number), num_(static_cast<double>(n)) {}
    Json(uint64_t n) : type_(Type::Number), num_(static_cast<double>(n)) {}
    Json(const char* s) : type_(Type::String), str_(s) {}
    Json(std::string s) : type_(Type::String), str_(std::move(s)) {}
    Json(Array a) : type_(Type::Array), arr_(std::move(a)) {}
    Json(Object o) : type_(Type::Object), obj_(std::move(o)) {}

    static Json array() { return Json(Array{}); }
    static Json object() { return Json(Object{}); }

    Type type() const { return type_; }
    bool isNull() const { return type_ == Type::Null; }
    bool isNumber() const { return type_ == Type::Number; }
    bool isString() const { return type_ == Type::String; }
    bool isArray() const { return type_ == Type::Array; }
    bool isObject() const { return type_ == Type::Object; }

    double number(double fallback = 0) const { return type_ == Type::Number ? num_ : fallback; }
    bool boolean(bool fallback = false) const { return type_ == Type::Bool ? bool_ : fallback; }
    const std::string& string() const { return str_; }
    const Array& items() const { return arr_; }
    const Object& members() const { return obj_; }

    // Object access. `get` returns a shared null for missing keys / non-objects.
    const Json& get(std::string_view key) const;
    bool has(std::string_view key) const;
    Json& set(std::string key, Json value);  // appends or replaces
    void push(Json value) { arr_.push_back(std::move(value)); }

    std::string dump(int indent = 2) const;
    // Returns false and fills `error` (with a byte offset) on malformed input.
    static bool parse(std::string_view text, Json& out, std::string& error);

private:
    void dumpTo(std::string& out, int indent, int depth) const;

    Type type_ = Type::Null;
    bool bool_ = false;
    double num_ = 0;
    std::string str_;
    Array arr_;
    Object obj_;
};

}  // namespace mf
