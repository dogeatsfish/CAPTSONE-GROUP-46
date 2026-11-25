#pragma once // Prevents multiple inclusion in the same translation unit

// Thin cross-platform wrapper over the handful of UDP socket calls the online
// simulation uses. All the #ifdef _WIN32 lives here so online_simulation.cpp
// is written once against net:: and never branches on the platform itself.
//
// The differences being papered over:
//   * Headers:      POSIX <sys/socket.h> etc.  vs  Winsock <winsock2.h>
//   * Handle type:  int (-1 = invalid)         vs  SOCKET, an UNSIGNED integer
//                   (INVALID_SOCKET), so "fd < 0" checks are wrong on Windows
//   * Close:        close()                    vs  closesocket()
//   * Startup:      nothing                    vs  WSAStartup()/WSACleanup()
//   * Buffers:      void* / size_t             vs  char* / int
//   * select():     first arg is max fd + 1    vs  ignored

#include <cstddef>
#include <cstdint>

#ifdef _WIN32
  #ifndef WIN32_LEAN_AND_MEAN
  #define WIN32_LEAN_AND_MEAN // keep <windows.h> from pulling in old winsock.h
  #endif
  #ifndef NOMINMAX
  #define NOMINMAX            // keep min/max macros from breaking std::min
  #endif
  // MinGW hides inet_pton unless the target is at least Vista (0x0600).
  #if !defined(_WIN32_WINNT) || _WIN32_WINNT < 0x0600
  #undef  _WIN32_WINNT
  #define _WIN32_WINNT 0x0600
  #endif
  #include <winsock2.h>
  #include <ws2tcpip.h>       // inet_pton, socklen_t
  // Link with ws2_32 (MinGW: -lws2_32; MSVC picks this up automatically).
  #ifdef _MSC_VER
  #pragma comment(lib, "ws2_32.lib")
  #endif
#else
  #include <unistd.h>
  #include <sys/socket.h>
  #include <sys/select.h>
  #include <netinet/in.h>
  #include <arpa/inet.h>
#endif

namespace net {

#ifdef _WIN32
using socket_t = SOCKET;
constexpr socket_t INVALID_SOCK = INVALID_SOCKET;
#else
using socket_t = int;
constexpr socket_t INVALID_SOCK = -1;
#endif

// RAII guard for the Winsock library. Windows refuses every socket call until
// WSAStartup() has run; POSIX needs nothing, so this is a no-op there.
// WSAStartup is reference-counted, so nesting guards is safe.
class Session {
public:
    Session() {
#ifdef _WIN32
        WSADATA data;
        ok_ = (::WSAStartup(MAKEWORD(2, 2), &data) == 0);
#endif
    }
    ~Session() {
#ifdef _WIN32
        if (ok_) ::WSACleanup();
#endif
    }
    Session(const Session&) = delete;
    Session& operator=(const Session&) = delete;

    bool ok() const { return ok_; }

private:
    bool ok_ = true;
};

inline socket_t open_udp() {
    return ::socket(AF_INET, SOCK_DGRAM, 0);
}

inline void close_socket(socket_t s) {
#ifdef _WIN32
    ::closesocket(s);
#else
    ::close(s);
#endif
}

inline void set_reuse_addr(socket_t s) {
    int yes = 1;
    ::setsockopt(s, SOL_SOCKET, SO_REUSEADDR,
                 reinterpret_cast<const char*>(&yes), sizeof(yes));
}

inline bool bind_any(socket_t s, uint16_t port) {
    sockaddr_in addr{};
    addr.sin_family      = AF_INET;
    addr.sin_addr.s_addr = htonl(INADDR_ANY);
    addr.sin_port        = htons(port);
    return ::bind(s, reinterpret_cast<const sockaddr*>(&addr), sizeof(addr)) == 0;
}

// Blocks until s is readable or timeout_ms elapses.
// Returns >0 readable, 0 timeout, <0 error (same contract as select()).
inline int wait_readable(socket_t s, long timeout_ms) {
    fd_set rfds;
    FD_ZERO(&rfds);
    FD_SET(s, &rfds);
    // timeval's field types differ per platform (macOS: int usec; Linux and
    // Windows: long), so cast to whatever this platform declares.
    timeval tv{};
    tv.tv_sec  = static_cast<decltype(tv.tv_sec)>(timeout_ms / 1000);
    tv.tv_usec = static_cast<decltype(tv.tv_usec)>((timeout_ms % 1000) * 1000);
#ifdef _WIN32
    return ::select(0, &rfds, nullptr, nullptr, &tv); // nfds ignored on Windows
#else
    return ::select(s + 1, &rfds, nullptr, nullptr, &tv);
#endif
}

inline long send_to(socket_t s, const uint8_t* data, size_t len,
                    const sockaddr_in& dest) {
    return ::sendto(s, reinterpret_cast<const char*>(data), static_cast<int>(len), 0,
                    reinterpret_cast<const sockaddr*>(&dest), sizeof(dest));
}

// Receives one datagram into buf; fills src with the sender's address.
// Returns bytes received, or <= 0 on error.
inline long recv_from(socket_t s, uint8_t* buf, size_t len, sockaddr_in& src) {
    socklen_t src_len = sizeof(src);
    return ::recvfrom(s, reinterpret_cast<char*>(buf), static_cast<int>(len), 0,
                      reinterpret_cast<sockaddr*>(&src), &src_len);
}

// Builds an IPv4 destination from a dotted-quad string ("192.168.0.1").
inline sockaddr_in make_addr(const char* ip, uint16_t port) {
    sockaddr_in addr{};
    addr.sin_family = AF_INET;
    addr.sin_port   = htons(port);
    ::inet_pton(AF_INET, ip, &addr.sin_addr);
    return addr;
}

} // namespace net
