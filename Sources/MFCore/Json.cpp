#include "mf/Json.hpp"

#include <charconv>
#include <cmath>
#include <cstdio>

namespace mf {

namespace {

const Json kNull;

void escapeString(std::string& out, const std::string& s) {
    out.push_back('"');
    for (unsigned char c : s) {
        switch (c) {
            case '"': out += "\\\""; break;
            case '\\': out += "\\\\"; break;
            case '\n': out += "\\n"; break;
            case '\r': out += "\\r"; break;
            case '\t': out += "\\t"; break;
            case '\b': out += "\\b"; break;
            case '\f': out += "\\f"; break;
            default:
                if (c < 0x20) {
                    char buf[8];
                    std::snprintf(buf, sizeof buf, "\\u%04x", c);
                    out += buf;
                } else {
                    out.push_back(static_cast<char>(c));
                }
        }
    }
    out.push_back('"');
}

void appendNumber(std::string& out, double v) {
    if (!std::isfinite(v)) {  // JSON has no NaN/Inf; store null-equivalent zero
        out += "0";
        return;
    }
    if (v == std::floor(v) && std::abs(v) < 9.0e15) {
        char buf[32];
        auto r = std::to_chars(buf, buf + sizeof buf, static_cast<long long>(v));
        out.append(buf, r.ptr);
        return;
    }
    char buf[64];
    auto r = std::to_chars(buf, buf + sizeof buf, v);  // shortest round-trip representation
    out.append(buf, r.ptr);
}

struct Parser {
    std::string_view s;
    size_t i = 0;
    std::string err;

    bool fail(const char* msg) {
        err = std::string(msg) + " at offset " + std::to_string(i);
        return false;
    }
    void ws() {
        while (i < s.size() && (s[i] == ' ' || s[i] == '\n' || s[i] == '\r' || s[i] == '\t')) ++i;
    }
    bool literal(std::string_view lit) {
        if (s.substr(i, lit.size()) != lit) return false;
        i += lit.size();
        return true;
    }
    static void appendUtf8(std::string& out, uint32_t cp) {
        if (cp < 0x80) {
            out.push_back(static_cast<char>(cp));
        } else if (cp < 0x800) {
            out.push_back(static_cast<char>(0xC0 | (cp >> 6)));
            out.push_back(static_cast<char>(0x80 | (cp & 0x3F)));
        } else if (cp < 0x10000) {
            out.push_back(static_cast<char>(0xE0 | (cp >> 12)));
            out.push_back(static_cast<char>(0x80 | ((cp >> 6) & 0x3F)));
            out.push_back(static_cast<char>(0x80 | (cp & 0x3F)));
        } else {
            out.push_back(static_cast<char>(0xF0 | (cp >> 18)));
            out.push_back(static_cast<char>(0x80 | ((cp >> 12) & 0x3F)));
            out.push_back(static_cast<char>(0x80 | ((cp >> 6) & 0x3F)));
            out.push_back(static_cast<char>(0x80 | (cp & 0x3F)));
        }
    }
    bool hex4(uint32_t& v) {
        if (i + 4 > s.size()) return fail("truncated \\u escape");
        v = 0;
        for (int k = 0; k < 4; ++k) {
            const char c = s[i++];
            v <<= 4;
            if (c >= '0' && c <= '9') v |= c - '0';
            else if (c >= 'a' && c <= 'f') v |= c - 'a' + 10;
            else if (c >= 'A' && c <= 'F') v |= c - 'A' + 10;
            else return fail("bad \\u escape");
        }
        return true;
    }
    bool str(std::string& out) {
        ++i;  // opening quote
        while (i < s.size()) {
            const char c = s[i++];
            if (c == '"') return true;
            if (c != '\\') {
                out.push_back(c);
                continue;
            }
            if (i >= s.size()) break;
            const char e = s[i++];
            switch (e) {
                case '"': out.push_back('"'); break;
                case '\\': out.push_back('\\'); break;
                case '/': out.push_back('/'); break;
                case 'n': out.push_back('\n'); break;
                case 'r': out.push_back('\r'); break;
                case 't': out.push_back('\t'); break;
                case 'b': out.push_back('\b'); break;
                case 'f': out.push_back('\f'); break;
                case 'u': {
                    uint32_t cp;
                    if (!hex4(cp)) return false;
                    if (cp >= 0xD800 && cp <= 0xDBFF && literal("\\u")) {
                        uint32_t lo;
                        if (!hex4(lo)) return false;
                        cp = 0x10000 + ((cp - 0xD800) << 10) + (lo - 0xDC00);
                    }
                    appendUtf8(out, cp);
                    break;
                }
                default: return fail("bad escape");
            }
        }
        return fail("unterminated string");
    }
    bool value(Json& out, int depth) {
        if (depth > 256) return fail("nesting too deep");
        ws();
        if (i >= s.size()) return fail("unexpected end");
        const char c = s[i];
        if (c == '{') {
            ++i;
            out = Json::object();
            ws();
            if (i < s.size() && s[i] == '}') { ++i; return true; }
            while (true) {
                ws();
                if (i >= s.size() || s[i] != '"') return fail("expected key");
                std::string key;
                if (!str(key)) return false;
                ws();
                if (i >= s.size() || s[i] != ':') return fail("expected ':'");
                ++i;
                Json v;
                if (!value(v, depth + 1)) return false;
                out.set(std::move(key), std::move(v));
                ws();
                if (i < s.size() && s[i] == ',') { ++i; continue; }
                if (i < s.size() && s[i] == '}') { ++i; return true; }
                return fail("expected ',' or '}'");
            }
        }
        if (c == '[') {
            ++i;
            out = Json::array();
            ws();
            if (i < s.size() && s[i] == ']') { ++i; return true; }
            while (true) {
                Json v;
                if (!value(v, depth + 1)) return false;
                out.push(std::move(v));
                ws();
                if (i < s.size() && s[i] == ',') { ++i; continue; }
                if (i < s.size() && s[i] == ']') { ++i; return true; }
                return fail("expected ',' or ']'");
            }
        }
        if (c == '"') {
            std::string v;
            if (!str(v)) return false;
            out = Json(std::move(v));
            return true;
        }
        if (literal("true")) { out = Json(true); return true; }
        if (literal("false")) { out = Json(false); return true; }
        if (literal("null")) { out = Json(); return true; }
        double d = 0;
        auto r = std::from_chars(s.data() + i, s.data() + s.size(), d);
        if (r.ec != std::errc()) return fail("bad value");
        i = static_cast<size_t>(r.ptr - s.data());
        out = Json(d);
        return true;
    }
};

}  // namespace

const Json& Json::get(std::string_view key) const {
    if (type_ != Type::Object) return kNull;
    for (const auto& [k, v] : obj_)
        if (k == key) return v;
    return kNull;
}

bool Json::has(std::string_view key) const {
    if (type_ != Type::Object) return false;
    for (const auto& kv : obj_)
        if (kv.first == key) return true;
    return false;
}

Json& Json::set(std::string key, Json value) {
    if (type_ != Type::Object) *this = object();
    for (auto& kv : obj_)
        if (kv.first == key) {
            kv.second = std::move(value);
            return kv.second;
        }
    obj_.emplace_back(std::move(key), std::move(value));
    return obj_.back().second;
}

void Json::dumpTo(std::string& out, int indent, int depth) const {
    auto newline = [&](int d) {
        if (indent <= 0) return;
        out.push_back('\n');
        out.append(static_cast<size_t>(indent * d), ' ');
    };
    switch (type_) {
        case Type::Null: out += "null"; break;
        case Type::Bool: out += bool_ ? "true" : "false"; break;
        case Type::Number: appendNumber(out, num_); break;
        case Type::String: escapeString(out, str_); break;
        case Type::Array: {
            // Short arrays of numbers (vectors, colours) stay on one line for readability.
            bool flat = arr_.size() <= 4;
            for (const auto& v : arr_) flat = flat && v.type_ == Type::Number;
            out.push_back('[');
            for (size_t k = 0; k < arr_.size(); ++k) {
                if (k) out += flat ? ", " : ",";
                if (!flat) newline(depth + 1);
                arr_[k].dumpTo(out, indent, depth + 1);
            }
            if (!flat && !arr_.empty()) newline(depth);
            out.push_back(']');
            break;
        }
        case Type::Object: {
            out.push_back('{');
            for (size_t k = 0; k < obj_.size(); ++k) {
                if (k) out.push_back(',');
                newline(depth + 1);
                escapeString(out, obj_[k].first);
                out += indent > 0 ? ": " : ":";
                obj_[k].second.dumpTo(out, indent, depth + 1);
            }
            if (!obj_.empty()) newline(depth);
            out.push_back('}');
            break;
        }
    }
}

std::string Json::dump(int indent) const {
    std::string out;
    dumpTo(out, indent, 0);
    return out;
}

bool Json::parse(std::string_view text, Json& out, std::string& error) {
    Parser p;
    p.s = text;
    Json v;
    if (!p.value(v, 0)) {
        error = p.err;
        return false;
    }
    p.ws();
    if (p.i != text.size()) {
        error = "trailing characters at offset " + std::to_string(p.i);
        return false;
    }
    out = std::move(v);
    return true;
}

}  // namespace mf
