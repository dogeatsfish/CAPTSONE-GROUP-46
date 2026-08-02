#pragma once

// Minimal flat INI reader for the C++ test harness.
//
// Format: "key = value" per line, "#" or ";" start a comment, blank lines and
// a single optional "[section]" header (ignored) are skipped. No nesting, no
// quoting -- this is a test-only config loader, not a general parser.
//
// Lets tests/config/*.ini own the socket addresses/ports/transport/dataset
// for each test instead of those values being hardcoded in the .cpp files.

#include <cctype>
#include <fstream>
#include <iostream>
#include <map>
#include <string>

class IniConfig {
public:
    // Returns false (and prints why) if the file can't be opened.
    bool load(const std::string& path) {
        std::ifstream in(path);
        if (!in) {
            std::cerr << "FAIL: could not open config file " << path << "\n";
            return false;
        }
        std::string line;
        while (std::getline(in, line)) {
            const std::string trimmed = trim(line);
            if (trimmed.empty() || trimmed[0] == '#' || trimmed[0] == ';') continue;
            if (trimmed.front() == '[' && trimmed.back() == ']') continue; // section header

            const size_t eq = trimmed.find('=');
            if (eq == std::string::npos) continue;
            values[trim(trimmed.substr(0, eq))] = trim(trimmed.substr(eq + 1));
        }
        return true;
    }

    std::string get_string(const std::string& key, const std::string& fallback) const {
        const auto it = values.find(key);
        return it == values.end() ? fallback : it->second;
    }

    uint16_t get_port(const std::string& key, uint16_t fallback) const {
        const auto it = values.find(key);
        return it == values.end() ? fallback
                                   : static_cast<uint16_t>(std::stoi(it->second));
    }

    double get_double(const std::string& key, double fallback) const {
        const auto it = values.find(key);
        return it == values.end() ? fallback : std::stod(it->second);
    }

private:
    std::map<std::string, std::string> values;

    static std::string trim(const std::string& s) {
        size_t a = 0, b = s.size();
        while (a < b && std::isspace(static_cast<unsigned char>(s[a]))) ++a;
        while (b > a && std::isspace(static_cast<unsigned char>(s[b - 1]))) --b;
        return s.substr(a, b - a);
    }
};
