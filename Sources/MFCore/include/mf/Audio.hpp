// MotionForge — what a composition sounds like: its audio layers, including those inside precomps,
// flattened to clips on the composition's own timeline. Playback and export both mix from this.
#pragma once

#include <cstdint>
#include <string>
#include <utility>
#include <vector>

#include "mf/Model.hpp"

namespace mf {

struct AudioClip {
    ObjectId layer = 0;     // the audio layer (in whichever composition it lives)
    ObjectId asset = 0;
    std::string path;
    double start = 0;        // seconds on the top composition's timeline
    double sourceStart = 0;  // seconds into the file
    double duration = 0;
    // Linear gain over the clip as (time on the top timeline, gain 0–1) breakpoints, ramped between;
    // a single point means a constant gain.
    std::vector<std::pair<double, double>> gain;
    bool operator==(const AudioClip&) const = default;
};

// Every audible clip of `comp` within [from, to) of its timeline (to <= from: to the end). Muted
// (hidden) audio layers and missing files are left out; time-remapped precomps are not followed.
std::vector<AudioClip> collectAudio(const Project& project, ObjectId comp, double from = 0, double to = 0);

// Audio Level (dB) to linear gain; the bottom of the range is silence.
double audioLevelGain(double dB);

}  // namespace mf
