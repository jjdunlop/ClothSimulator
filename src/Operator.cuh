#ifndef OPERATOR_CUH
#define OPERATOR_CUH

#include <algorithm>
#include <vector>
#include <unordered_set>
#include <unordered_map>

#include <thrust/device_vector.h>
#include <thrust/remove.h>

#include "MathHelper.cuh"
#include "CudaHelper.cuh"
#include "RemeshingHelper.cuh"
#include "Pair.cuh"
#include "Node.cuh"
#include "Vertex.cuh"
#include "Edge.cuh"
#include "Face.cuh"
#include "Material.cuh"
#include "MemoryPool.cuh"

class Operator {
public:
    std::vector<Node*> addedNodes, removedNodes;
    std::vector<Vertex*> addedVertices, removedVertices;
    std::vector<Edge*> addedEdges, removedEdges;
    std::vector<Face*> addedFaces, removedFaces;
    thrust::device_vector<Node*> addedNodesGpu, removedNodesGpu;
    thrust::device_vector<Vertex*> addedVerticesGpu, removedVerticesGpu;
    thrust::device_vector<Edge*> addedEdgesGpu, removedEdgesGpu;
    thrust::device_vector<Face*> addedFacesGpu, removedFacesGpu;
    Operator();
    ~Operator();
    void flip(const Edge* edge, const Material* material, MemoryPool* pool);
    void flip(const thrust::device_vector<Edge*>& edges, const Material* material, MemoryPool* pool);
    void split(const Edge* edge, const Material* material, MemoryPool* pool);
    void split(const thrust::device_vector<Edge*>& edges, const Material* material, MemoryPool* pool);
    void collapse(const Edge* edge, int side, const Material* material, const std::unordered_map<Node*, std::vector<Edge*>>& adjacentEdges, const std::unordered_map<Node*, std::vector<Face*>>& adjacentFaces, MemoryPool* pool);
    void collapse(const thrust::device_vector<PairEi>& edges, const Material* material, const thrust::device_vector<int>& edgeBegin, const thrust::device_vector<int>& edgeEnd, const thrust::device_vector<Edge*>& adjacentEdges, const thrust::device_vector<int>& faceBegin, const thrust::device_vector<int>& faceEnd, const thrust::device_vector<Face*>& adjacentFaces, MemoryPool* pool);
};

#endif