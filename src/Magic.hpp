#ifndef MAGIC_HPP
#define MAGIC_HPP

#include <json/json.h>

#include "JsonHelper.hpp"

class Magic {
public:
    float handleStiffness;
    float repulsionThickness, collisionThickness;
    Magic(const Json::Value& json);
    ~Magic();
};

#endif