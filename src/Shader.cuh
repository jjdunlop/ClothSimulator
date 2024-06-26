#ifndef SHADER_CUH
#define SHADER_CUH

#include <string>
#include <iostream>
#include <fstream>
#include <sstream>

#include <glad/glad.h>

#include "Vector.cuh"
#include "Matrix.cuh"

class Shader {
private:
    unsigned int program;

public:
    Shader(const std::string& vertexShaderPath, const std::string& fragmentShaderPath);
    ~Shader();
    void use() const;
    void setInt(const std::string& name, int value) const;
    void setFloat(const std::string& name, float value) const;
    void setVec3(const std::string& name, const Vector3f& value) const;
    void setMat4(const std::string& name, const Matrix4x4f& value) const;
};

#endif