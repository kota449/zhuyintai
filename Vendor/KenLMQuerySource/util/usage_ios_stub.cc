#include "usage.hh"

#include <ostream>

namespace util {

double WallTime() { return 0.0; }
double CPUTime() { return 0.0; }
double ThreadTime() { return 0.0; }
uint64_t RSSMax() { return 0; }
void PrintUsage(std::ostream &to) { (void)to; }
uint64_t GuessPhysicalMemory() { return 0; }
uint64_t ParseSize(const std::string &arg) {
    (void)arg;
    return 0;
}

}  // namespace util
