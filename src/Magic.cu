#include "Magic.cuh"

Magic::~Magic() {}

Magic::Magic(const Json::Value& json) :
    handleStiffness(1e3f),
    collisionStiffness(1e9f),
    repulsionThickness(1e-3f),
    collisionThickness(1e-4f) {
    if (json.isNull())
        return;

    handleStiffness = parseFloat(json["handle_stiffness"], handleStiffness);
    collisionStiffness = parseFloat(json["collision_stiffness"], collisionStiffness);
    repulsionThickness = parseFloat(json["repulsion_thickness"], repulsionThickness);
    collisionThickness = parseFloat(json["projection_thickness"], 0.1f * repulsionThickness);
}
