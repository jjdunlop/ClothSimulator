#ifndef OBSTACLE_HPP
#define OBSTACLE_HPP

#include <json/json.h>

#include "TypeHelper.hpp"
#include "Transform.hpp"
#include "Mesh.hpp"
#include "Shader.hpp"

class Obstacle {
private:
    Mesh* mesh;
    Shader* shader;

public:
    Obstacle(const Json::Value& json);
    ~Obstacle();
    Mesh* getMesh() const;
    void render(const Matrix4x4f& model, const Matrix4x4f& view, const Matrix4x4f& projection, const Vector3f& cameraPosition, const Vector3f& lightPosition, float lightPower) const;
};

#endif