#include "Obstacle.hpp"

Obstacle::Obstacle(const Json::Value& json) {
    Transform* transform = new Transform(json["transform"]);
    mesh = new Mesh(json["mesh"], transform);
    shader = new Shader("shader/VertexShader.glsl", "shader/FaceFragmentShader.glsl");
    delete transform;
}

Obstacle::~Obstacle() {
    delete mesh;
    delete shader;
}

Mesh* Obstacle::getMesh() const {
    return mesh;
}

void Obstacle::render(const Matrix4x4f& model, const Matrix4x4f& view, const Matrix4x4f& projection, const Vector3f& cameraPosition, const Vector3f& lightPosition, float lightPower) const {
    shader->use();
    shader->setMat4("model", model);
    shader->setMat4("view", view);
    shader->setMat4("projection", projection);
    shader->setVec3("color", Vector3f(0.8f, 0.8f, 0.8f));
    shader->setVec3("cameraPosition", cameraPosition);
    shader->setVec3("lightPosition", lightPosition);
    shader->setFloat("lightPower", lightPower);
    mesh->renderFace();
}