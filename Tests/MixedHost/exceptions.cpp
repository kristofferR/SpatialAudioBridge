#include <stdexcept>
#include <string>

struct Dropped {
    bool &value;
    ~Dropped() { value = true; }
};

extern "C" int host_cxx_catches(void) {
    bool dropped = false;
    try {
        Dropped guard{dropped};
        throw std::runtime_error("mixed-host deliberate exception");
    } catch (const std::runtime_error &error) {
        return dropped && std::string(error.what()) == "mixed-host deliberate exception";
    }
    return 0;
}
