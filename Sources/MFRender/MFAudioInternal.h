// MotionForge — audio clips between the C++ model and AVFoundation (shared by MFEngine and the exporter).
#pragma once

#import "MFEngine.h"

#include <vector>

#include "mf/Audio.hpp"

NSArray<MFAudioClipInfo*>* MFAudioClipInfos(const std::vector<mf::AudioClip>& clips);
