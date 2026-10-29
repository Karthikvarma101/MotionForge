#include "mf/Audio.hpp"

#include <algorithm>
#include <cmath>

#include "mf/Evaluator.hpp"

namespace mf {

double audioLevelGain(double dB) {
    if (dB <= propDef(PropId::AudioLevel).minValue + 1e-6) return 0;
    return std::pow(10.0, std::min(dB, 0.0) / 20.0);
}

namespace {

constexpr double kGainStep = 0.1;  // seconds between gain samples of an animated level

// `offset`: top time = local time + offset. [w0, w1): the part of the top timeline this
// composition can be heard in (clipped by every enclosing precomp layer).
void collect(const Project& p, const Composition& c, double offset, double w0, double w1, int depth,
             std::vector<AudioClip>& out) {
    for (const Layer& l : c.layers) {
        const Asset* footage = l.kind == LayerKind::Image ? p.findAsset(l.asset) : nullptr;
        if (l.kind == LayerKind::Audio || (footage && footage->isVideo() && footage->hasAudio)) {
            // Audio layers: the speaker switch. Video plays its sound whether or not the picture
            // is shown (as in After Effects); its Audio Level turns it down.
            if (l.kind == LayerKind::Audio && !l.visible) continue;
            const Asset* a = p.findAsset(l.asset);
            if (!a || a->missing || (a->kind != AssetKind::Audio && !a->hasAudio) || a->duration <= 0) continue;
            const double s = std::max({l.inPoint, l.startTime, w0 - offset});
            const double e = std::min({l.outPoint, l.startTime + a->duration, w1 - offset});
            if (e - s < 1e-4) continue;
            AudioClip clip;
            clip.layer = l.id;
            clip.asset = a->id;
            clip.path = a->path;
            clip.start = s + offset;
            clip.sourceStart = s - l.startTime;
            clip.duration = e - s;
            const Property& level = l.prop(PropId::AudioLevel);
            if (!level.animated() && !level.baked()) {
                clip.gain = {{clip.start, audioLevelGain(evaluateProperty(level, PropId::AudioLevel, s)[0])}};
            } else {
                std::vector<double> times;
                for (double t = s; t < e; t += kGainStep) times.push_back(t);
                for (const Keyframe& k : level.keyframes)
                    if (k.time > s && k.time < e) times.push_back(k.time);
                times.push_back(e);
                std::sort(times.begin(), times.end());
                times.erase(std::unique(times.begin(), times.end(), [](double x, double y) { return y - x < 1e-6; }),
                            times.end());
                for (double t : times)
                    clip.gain.push_back({t + offset, audioLevelGain(evaluateProperty(level, PropId::AudioLevel, t)[0])});
            }
            out.push_back(std::move(clip));
        } else if (l.kind == LayerKind::Precomp && !l.timeRemap && depth + 1 < kMaxNesting) {
            const Composition* src = p.findComposition(l.source);
            if (!src || src->id == c.id) continue;
            // The source plays from `startTime`, only while the layer is active and within its own length.
            const double s = std::max({l.inPoint, l.startTime, w0 - offset});
            const double e = std::min({l.outPoint, l.startTime + src->duration, w1 - offset});
            if (e - s < 1e-4) continue;
            collect(p, *src, offset + l.startTime, s + offset, e + offset, depth + 1, out);
        }
    }
}

}  // namespace

std::vector<AudioClip> collectAudio(const Project& project, ObjectId comp, double from, double to) {
    std::vector<AudioClip> out;
    const Composition* c = project.findComposition(comp);
    if (!c) return out;
    const double end = to > from ? std::min(to, c->duration) : c->duration;
    collect(project, *c, 0, std::max(0.0, from), end, 0, out);
    std::sort(out.begin(), out.end(), [](const AudioClip& a, const AudioClip& b) { return a.start < b.start; });
    return out;
}

}  // namespace mf
