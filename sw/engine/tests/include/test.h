#pragma once
#include <cctype>
#include <fstream>
#include <iostream>
#include <map>
#include <string>

class TestConfig {
public:
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

    int get_int(const std::string& key, int fallback) const {
        const auto it = values.find(key);
        return it == values.end() ? fallback : std::stoi(it->second);
    }

    bool get_bool(const std::string& key, bool fallback) const {
        const auto it = values.find(key);
        if (it == values.end()) return fallback;
        return it->second == "true" || it->second == "1" || it->second == "yes";
    }

    bool has(const std::string& key) const { return values.count(key) > 0; }

private:
    std::map<std::string, std::string> values;

    static std::string trim(const std::string& s) {
        size_t a = 0, b = s.size();
        while (a < b && std::isspace(static_cast<unsigned char>(s[a]))) ++a;
        while (b > a && std::isspace(static_cast<unsigned char>(s[b - 1]))) --b;
        return s.substr(a, b - a);
    }
};
