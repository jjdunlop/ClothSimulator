#include "Simulator.cuh"

Simulator::Simulator(SimulationMode mode, const std::string& path, const std::string& directory, bool exportObstacles)
    : mode(mode), directory(directory), nFrames(0), exportObstacles(exportObstacles) {
    pool = mode != Replay ? new MemoryPool() : nullptr;
    renderer = mode == Simulate || mode == Resume || mode == Replay ? new Renderer(900, 900) : nullptr;

    std::ifstream fin(mode == Simulate || mode == SimulateOffline ? path : directory + "/config.json");
    if (!fin.is_open()) {
        std::cerr << "Failed to open configuration file: " << path << std::endl;
        exit(1);
    }
    fin >> json;
    fin.close();

    frameTime = parseFloat(json["frame_time"]);
    frameSteps = parseInt(json["frame_steps"]);
    endTime = parseFloat(json["end_time"], INFINITY);
    endFrame = parseInt(json["end_frame"], INT_MAX);
    dt =  frameTime / frameSteps;

    clothFriction = parseFloat(json["friction"], 0.6f);
    obstacleFriction = parseFloat(json["obs_friction"], 0.3f);
    gravity = parseVector3f(json["gravity"]);
    Wind* windTemp = new Wind(json["wind"]);
    if (!gpu)
        wind = windTemp;
    else {
        CUDA_CHECK(cudaMalloc(&wind, sizeof(Wind)));
        CUDA_CHECK(cudaMemcpy(wind, windTemp, sizeof(Wind), cudaMemcpyHostToDevice));
        delete windTemp;
    }

    magic = new Magic(json["magic"]);

    if (json["motions"].isArray()) {
        motions.resize(json["motions"].size());
        for (int i = 0; i < json["motions"].size(); i++)
            motions[i] = new Motion(json["motions"][i]);
    } else if (json["motions"].isObject()) {
        float fps = parseFloat(json["motions"]["fps"], 30.0f);
        Transformation transformation(json["motions"]["transform"]);

        std::string motionPath = parseString(json["motions"]["motfile"]);
        fin.open(motionPath);
        if (!fin.is_open()) {
            std::cerr << "Failed to open motion file: " << motionPath << std::endl;
            exit(1);
        }
        std::string s, t;
        int frames;
        fin >> s >> frames;

        std::vector<std::vector<Vector3f>> translations;
        std::vector<std::vector<Quaternion>> rotations;
        while (fin >> s >> t) {
            float w, x, y, z;

            translations.push_back(std::vector<Vector3f>());
            for (int i = 0; i < frames; i++) {
                fin >> x >> y >> z;
                translations.back().emplace_back(x, y, z);
            }

            fin >> s >> t;
            rotations.push_back(std::vector<Quaternion>());
            for (int i = 0; i < frames; i++) {
                fin >> w >> x >> y >> z;
                rotations.back().emplace_back(w, x, y, z);
            }
        }
        fin.close();

        motions.resize(translations.size());
        for (int i = 0; i < motions.size(); i++)
            motions[i] = new Motion(translations[i], rotations[i], transformation, fps);
    }
    transformations.resize(motions.size());
    transformationsGpu.resize(motions.size());
    updateTransformations();

    cloths.resize(json["cloths"].size());
    for (int i = 0; i < json["cloths"].size(); i++)
        cloths[i] = new Cloth(json["cloths"][i], pool);

    if (json["obstacles"].isArray()) {
        obstacles.resize(json["obstacles"].size());
        for (int i = 0; i < json["obstacles"].size(); i++)
            obstacles[i] = new Obstacle(json["obstacles"][i], transformations, pool);
    } else if (json["obstacles"].isString())
        for (int i = 0; ; i++) {
            std::string obstaclePath = stringFormat(parseString(json["obstacles"]), i);
            if (!std::filesystem::exists(obstaclePath))
                break;

            obstacles.push_back(new Obstacle(obstaclePath, i, transformations, pool));
        }

    for (const Json::Value& handleJson : json["handles"]) {
        int clothIndex = parseInt(handleJson["cloth"]);
        int motionIndex = parseInt(handleJson["motion"], -1);
        std::vector<int> nodeIndices(handleJson["nodes"].size());
        for (int i = 0; i < handleJson["nodes"].size(); i++)
            nodeIndices[i] = parseInt(handleJson["nodes"][i]);
        if (!gpu)
            cloths[clothIndex]->addHandles(nodeIndices, motionIndex, transformations);
        else
            cloths[clothIndex]->addHandles(nodeIndices, motionIndex, transformationsGpu);
    }

    for (int i = 0; i < json["disable"].size(); i++)
        disabled.insert(parseString(json["disable"][i]));
}

Simulator::~Simulator() {
    delete magic;
    for (const Motion* motion : motions)
        delete motion;
    for (const Cloth* cloth : cloths)
        delete cloth;
    for (const Obstacle* obstacle : obstacles)
        delete obstacle;
    delete renderer;
    delete pool;

    if (!gpu)
        delete wind;
    else
        CUDA_CHECK(cudaFree(wind));
}

std::string Simulator::stringFormat(const std::string format, ...) const {
    char buffer[256];
    va_list args;
    va_start(args, format);
    vsnprintf(buffer, 256, format.c_str(), args);
    va_end(args);
    return std::string(buffer);
}

std::vector<BVH*> Simulator::buildClothBvhs(bool ccd) const {
    std::vector<BVH*> ans(cloths.size());
    for (int i = 0; i < cloths.size(); i++)
        ans[i] = new BVH(cloths[i]->getMesh(), ccd);
    return ans;
}

std::vector<BVH*> Simulator::buildObstacleBvhs(bool ccd) const {
    std::vector<BVH*> ans(obstacles.size());
    for (int i = 0; i < obstacles.size(); i++)
        ans[i] = new BVH(obstacles[i]->getMesh(), ccd);
    return ans;
}

void Simulator::updateBvhs(std::vector<BVH*>& bvhs) const {
    for (BVH* bvh : bvhs)
        bvh->update();
}

void Simulator::destroyBvhs(const std::vector<BVH*>& bvhs) const {
    for (const BVH* bvh : bvhs)
        delete bvh;
}

void Simulator::traverse(const std::vector<BVH*>& clothBvhs, const std::vector<BVH*>& obstacleBvhs, float thickness, std::function<void(const Face*, const Face*, float)> callback) const {
    for (int i = 0; i < clothBvhs.size(); i++) {
        clothBvhs[i]->traverse(thickness, callback);
        for (int j = 0; j < i; j++)
            clothBvhs[i]->traverse(clothBvhs[j], thickness, callback);

        for (int j = 0; j < obstacleBvhs.size(); j++)
            clothBvhs[i]->traverse(obstacleBvhs[j], thickness, callback);
    }
}

thrust::device_vector<PairFF> Simulator::traverse(const std::vector<BVH*>& clothBvhs, const std::vector<BVH*>& obstacleBvhs, float thickness) const {
    thrust::device_vector<PairFF> ans, pairs;
    for (int i = 0; i < cloths.size(); i++) {
        pairs = std::move(clothBvhs[i]->traverse(thickness));
        ans.insert(ans.end(), pairs.begin(), pairs.end());

        for (int j = 0; j < i; j++) {
            pairs = std::move(clothBvhs[i]->traverse(clothBvhs[j], thickness));
            ans.insert(ans.end(), pairs.begin(), pairs.end());
        }

        for (int j = 0; j < obstacleBvhs.size(); j++) {
            pairs = std::move(clothBvhs[i]->traverse(obstacleBvhs[j], thickness));
            ans.insert(ans.end(), pairs.begin(), pairs.end());
        }
    }
    return ans;
}

void Simulator::checkVertexFaceProximity(const Vertex* vertex, const Face* face, std::unordered_map<PairNi, PairfF, PairHash>& nodeProximities, std::unordered_map<PairFi, PairfN, PairHash>& faceProximities) const {
    Node* node = vertex->node;
    Node* node0 = face->vertices[0]->node;
    Node* node1 = face->vertices[1]->node;
    Node* node2 = face->vertices[2]->node;
    if (node == node0 || node == node1 || node == node2)
        return;

    Vector3f n;
    float w[4];
    float d = abs(signedVertexFaceDistance(node->x, node0->x, node1->x, node2->x, n, w));
    bool inside = (min(-w[1], -w[2], -w[3]) >= 1e-6f);
    if (!inside)
        return;

    if (node->isFree) {
        int side = n.dot(node->n) >= 0.0f ? 0 : 1;
        PairNi key(node, side);
        PairfF value(d, const_cast<Face*>(face));
        if (nodeProximities.find(key) == nodeProximities.end())
            nodeProximities[key] = value;
        else
            nodeProximities[key] = min(nodeProximities[key], value);
    }
    if (face->isFree()) {
        int side = -n.dot(face->n) >= 0.0f ? 0 : 1;
        PairFi key(const_cast<Face*>(face), side);
        PairfN value(d, node);
        if (faceProximities.find(key) == faceProximities.end())
            faceProximities[key] = value;
        else
            faceProximities[key] = min(faceProximities[key], value);
    }
}

void Simulator::checkEdgeEdgeProximity(const Edge* edge0, const Edge* edge1, std::unordered_map<PairEi, PairfE, PairHash>& edgeProximities) const {
    Node* node0 = edge0->nodes[0];
    Node* node1 = edge0->nodes[1];
    Node* node2 = edge1->nodes[0];
    Node* node3 = edge1->nodes[1];
    if (node0 == node2 || node0 == node3 || node1 == node2 || node1 == node3)
        return;

    Vector3f n;
    float w[4];
    float d = abs(signedEdgeEdgeDistance(node0->x, node1->x, node2->x, node3->x, n, w));
    bool inside = (min(w[0], w[1], -w[2], -w[3]) >= 1e-6f && inEdge(w[1], edge0, edge1) && inEdge(-w[3], edge1, edge0));
    if (!inside)
        return;

    if (edge0->isFree()) {
        int side = n.dot(edge0->nodes[0]->n + edge0->nodes[1]->n) >= 0.0f ? 0 : 1;
        PairEi key(const_cast<Edge*>(edge0), side);
        PairfE value(d, const_cast<Edge*>(edge1));
        if (edgeProximities.find(key) == edgeProximities.end())
            edgeProximities[key] = value;
        else
            edgeProximities[key] = min(edgeProximities[key], value);
    }
    if (edge1->isFree()) {
        int side = -n.dot(edge1->nodes[0]->n + edge1->nodes[1]->n) >= 0.0f ? 0 : 1;
        PairEi key(const_cast<Edge*>(edge1), side);
        PairfE value(d, const_cast<Edge*>(edge0));
        if (edgeProximities.find(key) == edgeProximities.end())
            edgeProximities[key] = value;
        else
            edgeProximities[key] = min(edgeProximities[key], value);
    }
}

void Simulator::checkProximities(const Face* face0, const Face* face1, std::unordered_map<PairNi, PairfF, PairHash>& nodeProximities, std::unordered_map<PairEi, PairfE, PairHash>& edgeProximities, std::unordered_map<PairFi, PairfN, PairHash>& faceProximities) const {
    for (int i = 0; i < 3; i++)
        checkVertexFaceProximity(face0->vertices[i], face1, nodeProximities, faceProximities);
    for (int i = 0; i < 3; i++)
        checkVertexFaceProximity(face1->vertices[i], face0, nodeProximities, faceProximities);
    for (int i = 0; i < 3; i++)
        for (int j = 0; j < 3; j++)
            checkEdgeEdgeProximity(face0->edges[i], face1->edges[j], edgeProximities);
}

std::vector<Proximity> Simulator::findProximities(const std::vector<BVH*>& clothBvhs, const std::vector<BVH*>& obstacleBvhs) const {
    std::unordered_map<PairNi, PairfF, PairHash> nodeProximities;
    std::unordered_map<PairEi, PairfE, PairHash> edgeProximities;
    std::unordered_map<PairFi, PairfN, PairHash> faceProximities;
    traverse(clothBvhs, obstacleBvhs, 2.0f * magic->repulsionThickness, [&](const Face* face0, const Face* face1, float thickness) {
        checkProximities(face0, face1, nodeProximities, edgeProximities, faceProximities);
    });

    std::vector<Proximity> ans;
    for (const std::pair<PairNi, PairfF>& pair : nodeProximities)
        if (pair.second.first < 2.0f * magic->repulsionThickness)
            ans.emplace_back(pair.first.first, pair.second.second, magic->collisionStiffness, clothFriction, obstacleFriction);
    for (const std::pair<PairEi, PairfE>& pair : edgeProximities)
        if (pair.second.first < 2.0f * magic->repulsionThickness)
            ans.emplace_back(pair.first.first, pair.second.second, magic->collisionStiffness, clothFriction, obstacleFriction);
    for (const std::pair<PairFi, PairfN>& pair : faceProximities)
        if (pair.second.first < 2.0f * magic->repulsionThickness)
            ans.emplace_back(pair.second.second, pair.first.first, magic->collisionStiffness, clothFriction, obstacleFriction);

    return ans;
}

thrust::device_vector<Proximity> Simulator::findProximitiesGpu(const std::vector<BVH*>& clothBvhs, const std::vector<BVH*>& obstacleBvhs) const {
    thrust::device_vector<PairFF> pairs = std::move(traverse(clothBvhs, obstacleBvhs, 2.0f * magic->repulsionThickness));
    int nPairs = pairs.size();
    thrust::device_vector<PairNi> nodes(6 * nPairs);
    thrust::device_vector<PairfF> nodeProximities(6 * nPairs);
    thrust::device_vector<PairEi> edges(18 * nPairs);
    thrust::device_vector<PairfE> edgeProximities(18 * nPairs);
    thrust::device_vector<PairFi> faces(6 * nPairs);
    thrust::device_vector<PairfN> faceProximities(6 * nPairs);
    checkProximitiesGpu<<<GRID_SIZE, BLOCK_SIZE>>>(nPairs, pointer(pairs), pointer(nodes), pointer(nodeProximities), pointer(edges), pointer(edgeProximities), pointer(faces), pointer(faceProximities));
    CUDA_CHECK_LAST();

    nodeProximities.erase(thrust::remove_if(nodeProximities.begin(), nodeProximities.end(), nodes.begin(), IsNull()), nodeProximities.end());
    nodes.erase(thrust::remove_if(nodes.begin(), nodes.end(), IsNull()), nodes.end());
    thrust::sort_by_key(nodes.begin(), nodes.end(), nodeProximities.begin());
    thrust::device_vector<PairNi> outputNodes(nodes.size());
    thrust::device_vector<PairfF> outputNodeProximities(nodeProximities.size());
    auto nodeIter = thrust::reduce_by_key(nodes.begin(), nodes.end(), nodeProximities.begin(), outputNodes.begin(), outputNodeProximities.begin(), thrust::equal_to<PairNi>(), thrust::minimum<PairfF>());

    edgeProximities.erase(thrust::remove_if(edgeProximities.begin(), edgeProximities.end(), edges.begin(), IsNull()), edgeProximities.end());
    edges.erase(thrust::remove_if(edges.begin(), edges.end(), IsNull()), edges.end());
    thrust::sort_by_key(edges.begin(), edges.end(), edgeProximities.begin());
    thrust::device_vector<PairEi> outputEdges(edges.size());
    thrust::device_vector<PairfE> outputEdgeProximities(edgeProximities.size());
    auto edgeIter = thrust::reduce_by_key(edges.begin(), edges.end(), edgeProximities.begin(), outputEdges.begin(), outputEdgeProximities.begin(), thrust::equal_to<PairEi>(), thrust::minimum<PairfE>());

    faceProximities.erase(thrust::remove_if(faceProximities.begin(), faceProximities.end(), faces.begin(), IsNull()), faceProximities.end());
    faces.erase(thrust::remove_if(faces.begin(), faces.end(), IsNull()), faces.end());
    thrust::sort_by_key(faces.begin(), faces.end(), faceProximities.begin());
    thrust::device_vector<PairFi> outputFaces(faces.size());
    thrust::device_vector<PairfN> outputFaceProximities(faceProximities.size());
    auto faceIter = thrust::reduce_by_key(faces.begin(), faces.end(), faceProximities.begin(), outputFaces.begin(), outputFaceProximities.begin(), thrust::equal_to<PairFi>(), thrust::minimum<PairfN>());

    int nNodeProximities = nodeIter.first - outputNodes.begin();
    int nEdgeProximities = edgeIter.first - outputEdges.begin();
    int nFaceProximities = faceIter.first - outputFaces.begin();
    thrust::device_vector<Proximity> ans(nNodeProximities + nEdgeProximities + nFaceProximities);

    setNodeProximities<<<GRID_SIZE, BLOCK_SIZE>>>(nNodeProximities, pointer(outputNodes), pointer(outputNodeProximities), magic->repulsionThickness, magic->collisionStiffness, clothFriction, obstacleFriction, pointer(ans));
    CUDA_CHECK_LAST();

    setEdgeProximities<<<GRID_SIZE, BLOCK_SIZE>>>(nEdgeProximities, pointer(outputEdges), pointer(outputEdgeProximities), magic->repulsionThickness, magic->collisionStiffness, clothFriction, obstacleFriction, pointer(ans, nNodeProximities));
    CUDA_CHECK_LAST();

    setFaceProximities<<<GRID_SIZE, BLOCK_SIZE>>>(nFaceProximities, pointer(outputFaces), pointer(outputFaceProximities), magic->repulsionThickness, magic->collisionStiffness, clothFriction, obstacleFriction, pointer(ans, nNodeProximities + nEdgeProximities));
    CUDA_CHECK_LAST();

    ans.erase(thrust::remove_if(ans.begin(), ans.end(), IsNull()), ans.end());
    return ans;
}

void Simulator::updateActive(const std::vector<BVH*>& clothBvhs, const std::vector<BVH*>& obstacleBvhs, const std::vector<Impact>& impacts) const {
    for (BVH* clothBvh : clothBvhs)
        clothBvh->setAllActive(false);
    for (BVH* obstacleBvh : obstacleBvhs)
        obstacleBvh->setAllActive(false);

    for (const Impact& impact : impacts)
        for (int i = 0; i < 4; i++) {
            Node* node = impact.nodes[i];
            for (BVH* clothBvh : clothBvhs)
                if (clothBvh->contain(node))
                    clothBvh->setActive(node, true);
            for (BVH* obstacleBvh : obstacleBvhs)
                if (obstacleBvh->contain(node))
                    obstacleBvh->setActive(node, true);
        }
}

void Simulator::checkImpacts(const Face* face0, const Face* face1, float thickness, std::vector<Impact>& impacts) const {
    Impact impact;
    for (int i = 0; i < 3; i++)
        if (checkVertexFaceImpact(face0->vertices[i], face1, thickness, impact))
            impacts.push_back(impact);
    for (int i = 0; i < 3; i++)
        if (checkVertexFaceImpact(face1->vertices[i], face0, thickness, impact))
            impacts.push_back(impact);
    for (int i = 0; i < 3; i++)
        for (int j = 0; j < 3; j++)
            if (checkEdgeEdgeImpact(face0->edges[i], face1->edges[j], thickness, impact))
                impacts.push_back(impact);
}

thrust::device_vector<Impact> Simulator::findImpacts(const std::vector<BVH*>& clothBvhs, const std::vector<BVH*>& obstacleBvhs) const {
    thrust::device_vector<PairFF> pairs = std::move(traverse(clothBvhs, obstacleBvhs, magic->collisionThickness));
    int nPairs = pairs.size();
    thrust::device_vector<Impact> ans(15 * nPairs);
    checkImpactsGpu<<<GRID_SIZE, BLOCK_SIZE>>>(nPairs, pointer(pairs), magic->collisionThickness, pointer(ans));
    CUDA_CHECK_LAST();

    ans.erase(thrust::remove_if(ans.begin(), ans.end(), IsNull()), ans.end());
    return ans;
}

std::vector<Impact> Simulator::independentImpacts(const std::vector<Impact>& impacts, int deform) const {
    std::vector<Impact> sorted = impacts;
    std::sort(sorted.begin(), sorted.end());

    std::unordered_set<Node*> nodes;
    std::vector<Impact> ans;
    for (const Impact& impact : sorted) {
        bool flag = true;
        for (int i = 0; i < 4; i++) {
            Node* node = impact.nodes[i];
            if ((deform == 1 || node->isFree) && nodes.find(node) != nodes.end()) {
                flag = false;
                break;
            }
        }

        if (flag) {
            ans.push_back(impact);
            for (int i = 0; i < 4; i++) {
                Node* node = impact.nodes[i];
                if (deform == 1 || node->isFree)
                    nodes.insert(node);
            }
        }
    }
    return ans;
}

thrust::device_vector<Impact> Simulator::independentImpacts(const thrust::device_vector<Impact>& impacts, int deform) const {
    thrust::device_vector<Impact> sorted = impacts;
    thrust::sort(sorted.begin(), sorted.end());

    int nImpacts = sorted.size();
    const Impact* sortedPointer = pointer(sorted);
    int nNodes = 4 * nImpacts;
    thrust::device_vector<Impact> ans(nImpacts);
    Impact* ansPointer = pointer(ans);
    initializeImpactNodes<<<GRID_SIZE, BLOCK_SIZE>>>(nImpacts, sortedPointer, deform);
    CUDA_CHECK_LAST();

    int num, newNum = nImpacts;
    do {
        num = newNum;
        thrust::device_vector<Node*> nodes(nNodes);
        thrust::device_vector<int> relativeImpacts(nNodes);
        collectRelativeImpacts<<<GRID_SIZE, BLOCK_SIZE>>>(nImpacts, sortedPointer, deform, pointer(nodes), pointer(relativeImpacts));
        CUDA_CHECK_LAST();

        nodes.erase(thrust::remove(nodes.begin(), nodes.end(), nullptr), nodes.end());
        relativeImpacts.erase(thrust::remove(relativeImpacts.begin(), relativeImpacts.end(), -1), relativeImpacts.end());
        thrust::sort_by_key(nodes.begin(), nodes.end(), relativeImpacts.begin());
        thrust::device_vector<Node*> outputNodes(nNodes);
        thrust::device_vector<int> outputRelativeImpacts(nNodes);
        auto iter = thrust::reduce_by_key(nodes.begin(), nodes.end(), relativeImpacts.begin(), outputNodes.begin(), outputRelativeImpacts.begin(), thrust::equal_to<Node*>(), thrust::minimum<int>());
        setImpactMinIndices<<<GRID_SIZE, BLOCK_SIZE>>>(iter.first - outputNodes.begin(), pointer(outputRelativeImpacts), pointer(outputNodes));
        CUDA_CHECK_LAST();

        checkIndependentImpacts<<<GRID_SIZE, BLOCK_SIZE>>>(nImpacts, sortedPointer, deform, ansPointer);
        CUDA_CHECK_LAST();

        newNum = thrust::count_if(ans.begin(), ans.end(), IsNull());
    } while (num > newNum);

    ans.erase(thrust::remove_if(ans.begin(), ans.end(), IsNull()), ans.end());
    CUDA_CHECK_LAST();

    return ans;
}

void Simulator::updateActive(const std::vector<BVH*>& clothBvhs, const std::vector<BVH*>& obstacleBvhs, const std::vector<Intersection>& intersections) const {
    for (BVH* clothBvh : clothBvhs)
        clothBvh->setAllActive(false);
    for (BVH* obstacleBvh : obstacleBvhs)
        obstacleBvh->setAllActive(false);

    for (const Intersection& intersection : intersections)
        for (int i = 0; i < 3; i++) {
            Node* node0 = intersection.face0->vertices[i]->node;
            for (BVH* clothBvh : clothBvhs)
                if (clothBvh->contain(node0))
                    clothBvh->setActive(node0, true);
            for (BVH* obstacleBvh : obstacleBvhs)
                if (obstacleBvh->contain(node0))
                    obstacleBvh->setActive(node0, true);

            Node* node1 = intersection.face1->vertices[i]->node;
            for (BVH* clothBvh : clothBvhs)
                if (clothBvh->contain(node1))
                    clothBvh->setActive(node1, true);
            for (BVH* obstacleBvh : obstacleBvhs)
                if (obstacleBvh->contain(node1))
                    obstacleBvh->setActive(node1, true);
        }
}

Vector3f Simulator::oldPosition(const Vector2f& u, const std::vector<BackupFace>& faces) const {
    for (const BackupFace& face : faces) {
        Vector3f b = face.barycentricCoordinates(u);
        if (b(0) >= -1e-6f && b(1) >= -1e-6f && b(2) >= -1e-5f)
            return face.position(b);
    }
}

Vector3f Simulator::oldPosition(const Face* face, const Vector3f& b, const std::vector<std::vector<BackupFace>>& faces) const {
    if (!face->isFree())
        return face->position(b);

    Vector2f u = b(0) * face->vertices[0]->u + b(1) * face->vertices[1]->u + b(2) * face->vertices[2]->u;
    for (int i = 0; i < cloths.size(); i++)
        if (cloths[i]->getMesh()->contain(face))
            return oldPosition(u, faces[i]);
}

void Simulator::checkIntersection(const Face* face0, const Face* face1, std::vector<Intersection>& intersections, const std::vector<std::vector<BackupFace>>& faces) const {
    Intersection intersection;
    Vector3f& b0 = intersection.b0;
    Vector3f& b1 = intersection.b1;
    if (checkIntersectionMidpoint(face0, face1, b0, b1)) {
        intersection.face0 = const_cast<Face*>(face0);
        intersection.face1 = const_cast<Face*>(face1);
        Vector3f x0 = oldPosition(face0, b0, faces);
        Vector3f x1 = oldPosition(face1, b1, faces);
        Vector3f& d = intersection.d;
        d = (x0 - x1).normalized();
        farthestPoint(face0, face1, d, b0, b1);
        intersections.push_back(intersection);
    }
}

thrust::device_vector<Intersection> Simulator::findIntersections(const std::vector<BVH*>& clothBvhs, const std::vector<BVH*>& obstacleBvhs, const std::vector<thrust::device_vector<BackupFace>>& faces) const {
    thrust::device_vector<PairFF> pairs = std::move(traverse(clothBvhs, obstacleBvhs, magic->collisionThickness));
    int nPairs = pairs.size();
    thrust::device_vector<Intersection> ans(nPairs);
    Intersection* ansPointer = pointer(ans);
    checkIntersectionsGpu<<<GRID_SIZE, BLOCK_SIZE>>>(nPairs, pointer(pairs), ansPointer);
    CUDA_CHECK_LAST();

    ans.erase(thrust::remove_if(ans.begin(), ans.end(), IsNull()), ans.end());
    int nAns = ans.size();
    thrust::device_vector<Vector3f> x(2 * nAns);
    Vector3f* xPointer = pointer(x);
    initializeOldPosition<<<GRID_SIZE, BLOCK_SIZE>>>(nAns, ansPointer, xPointer);
    CUDA_CHECK_LAST();

    for (int i = 0; i < cloths.size(); i++) {
        const BackupFace* facesPointer = pointer(faces[i]);
        thrust::device_vector<Vertex*>& vertices = cloths[i]->getMesh()->getVerticesGpu();
        thrust::device_vector<int> indices(2 * nAns);
        int* indicesPointer = pointer(indices);
        thrust::device_vector<Vector2f> u(2 * nAns);
        Vector2f* uPointer = pointer(u);
        collectContainedFaces<<<GRID_SIZE, BLOCK_SIZE>>>(nAns, ansPointer, vertices.size(), pointer(vertices), indicesPointer, uPointer);
        CUDA_CHECK_LAST();

        u.erase(thrust::remove_if(u.begin(), u.end(), indices.begin(), IsNull()), u.end());
        indices.erase(thrust::remove(indices.begin(), indices.end(), -1), indices.end());
        thrust::device_vector<int> faceIndices(indices.size());
        int* faceIndicesPointer = pointer(faceIndices);
        computeEnclosingFaces<<<GRID_SIZE, BLOCK_SIZE>>>(indices.size(), uPointer, faces[i].size(), facesPointer, faceIndicesPointer);
        CUDA_CHECK_LAST();

        computeOldPositions<<<GRID_SIZE, BLOCK_SIZE>>>(indices.size(), indicesPointer, faceIndicesPointer, uPointer, facesPointer, xPointer);
        CUDA_CHECK_LAST();
    }

    computeFarthestPoint<<<GRID_SIZE, BLOCK_SIZE>>>(nAns, xPointer, ansPointer);
    CUDA_CHECK_LAST();

    return ans;
}

void Simulator::updateTransformations() {
    float time = nSteps * dt;
    for (int i = 0; i < motions.size(); i++)
        transformations[i] = transformationsGpu[i] = motions[i]->computeTransformation(time);
}

void Simulator::physicsStep() {
    for (Obstacle* obstacle : obstacles)
        obstacle->step(dt, transformations);

    std::vector<BVH*> clothBvhs = std::move(buildClothBvhs(false));
    std::vector<BVH*> obstacleBvhs = std::move(buildObstacleBvhs(false));

    if (!gpu) {
        std::vector<Proximity> proximities = std::move(findProximities(clothBvhs, obstacleBvhs));
        for (Cloth* cloth : cloths)
            cloth->physicsStep(dt, gravity, wind, transformations, magic->handleStiffness, proximities, magic->repulsionThickness);
    } else {
        thrust::device_vector<Proximity> proximities = std::move(findProximitiesGpu(clothBvhs, obstacleBvhs));
        for (Cloth* cloth : cloths)
            cloth->physicsStep(dt, gravity, wind, transformationsGpu, magic->handleStiffness, proximities, magic->repulsionThickness);
    }

    destroyBvhs(clothBvhs);
    destroyBvhs(obstacleBvhs);

    for (Cloth* cloth : cloths)
        cloth->getMesh()->updatePositions(dt);
    for (Obstacle* obstacle : obstacles)
        obstacle->getMesh()->updatePositions(dt);

    updateClothFaceGeometries();
    updateClothNodeGeometries();
    updateObstacleFaceGeometries();
    updateObstacleNodeGeometries();
}

void Simulator::collisionStep() {
    std::vector<BVH*> clothBvhs = std::move(buildClothBvhs(true));
    std::vector<BVH*> obstacleBvhs = std::move(buildObstacleBvhs(true));
    int deform;
    float obstacleMass = 1e3f;

    bool success = false;
    if (!gpu) {
        std::vector<Impact> impacts;
        for (deform = 0; deform < 2; deform++) {
            impacts.clear();
            for (int i = 0; i < MAX_COLLISION_ITERATION; i++) {
                if (!impacts.empty())
                    updateActive(clothBvhs, obstacleBvhs, impacts);

                std::vector<Impact> newImpacts;
                traverse(clothBvhs, obstacleBvhs, magic->collisionThickness, [&](const Face* face0, const Face* face1, float thickness) {
                    checkImpacts(face0, face1, thickness, newImpacts);
                });
                if (newImpacts.empty()) {
                    success = true;
                    break;
                }

                newImpacts = std::move(independentImpacts(newImpacts, deform));
                impacts.insert(impacts.end(), newImpacts.begin(), newImpacts.end());
                Optimization* optimization = new CollisionOptimization(impacts, magic->collisionThickness, deform, obstacleMass);
                optimization->solve();
                delete optimization;

                updateBvhs(clothBvhs);
                if (deform == 1) {
                    updateBvhs(obstacleBvhs);
                    obstacleMass *= 0.5f;
                }
            }
            if (success)
                break;
        }
    } else {
        thrust::device_vector<Impact> impacts;
        for (deform = 0; deform < 2; deform++) {
            impacts.clear();
            for (int i = 0; i < MAX_COLLISION_ITERATION; i++) {
                thrust::device_vector<Impact> newImpacts = std::move(findImpacts(clothBvhs, obstacleBvhs));
                if (newImpacts.empty()) {
                    success = true;
                    break;
                }

                newImpacts = std::move(independentImpacts(newImpacts, deform));
                impacts.insert(impacts.end(), newImpacts.begin(), newImpacts.end());
                Optimization* optimization = new CollisionOptimization(impacts, magic->collisionThickness, deform, obstacleMass);
                optimization->solve();
                delete optimization;

                updateBvhs(clothBvhs);
                if (deform == 1) {
                    updateBvhs(obstacleBvhs);
                    obstacleMass *= 0.5f;
                }
            }
            if (success)
                break;
        }
    }
    if (!success) {
        std::cerr << std::endl << "Collision step failed!" << std::endl;
        exit(1);
    }

    destroyBvhs(clothBvhs);
    destroyBvhs(obstacleBvhs);

    updateClothFaceGeometries();
    updateClothNodeGeometries();
    updateClothVelocities();
    if (deform == 1) {
        updateObstacleFaceGeometries();
        updateObstacleNodeGeometries();
        updateObstacleVelocities();
    }
}

void Simulator::remeshingStep() {
    std::vector<BVH*> obstacleBvhs = std::move(buildObstacleBvhs(false));
    for (Cloth* cloth : cloths)
        cloth->remeshingStep(obstacleBvhs, 10.0f * magic->repulsionThickness, pool);

    destroyBvhs(obstacleBvhs);

    updateClothFaceGeometries();
    updateClothNodeGeometries();
}

void Simulator::separationStep(const std::vector<std::vector<BackupFace>>& faces) {
    std::vector<BVH*> clothBvhs = std::move(buildClothBvhs(false));
    std::vector<BVH*> obstacleBvhs = std::move(buildObstacleBvhs(false));
    int deform;
    float obstacleArea = 1e3f;

    bool success = false;
    std::vector<Intersection> intersections;
    for (deform = 0; deform < 2; deform++) {
        intersections.clear();
        for (int i = 0; i < MAX_SEPARATION_ITERATION; i++) {
            if (!intersections.empty())
                updateActive(clothBvhs, obstacleBvhs, intersections);

            std::vector<Intersection> newIntersections;
            traverse(clothBvhs, obstacleBvhs, magic->collisionThickness, [&](const Face* face0, const Face* face1, float thickness) {
                checkIntersection(face0, face1, newIntersections, faces);
            });
            if (newIntersections.empty()) {
                success = true;
                break;
            }

            intersections.insert(intersections.end(), newIntersections.begin(), newIntersections.end());
            Optimization* optimization = new SeparationOptimization(intersections, magic->collisionThickness, deform, obstacleArea);
            optimization->solve();
            delete optimization;

            updateClothFaceGeometries();
            updateBvhs(clothBvhs);
            if (deform == 1) {
                updateObstacleFaceGeometries();
                updateBvhs(obstacleBvhs);
                obstacleArea *= 0.5f;
            }
        }
        if (success)
            break;
    }
    if (!success) {
        std::cerr << std::endl << "Separation step failed!" << std::endl;
        exit(1);
    }

    destroyBvhs(clothBvhs);
    destroyBvhs(obstacleBvhs);

    updateClothNodeGeometries();
    updateClothVelocities();
    if (deform == 1) {
        updateObstacleNodeGeometries();
        updateObstacleVelocities();
    }
}

void Simulator::separationStep(const std::vector<thrust::device_vector<BackupFace>>& faces) {
    std::vector<BVH*> clothBvhs = std::move(buildClothBvhs(false));
    std::vector<BVH*> obstacleBvhs = std::move(buildObstacleBvhs(false));
    int deform;
    float obstacleArea = 1e3f;

    bool success = false;
    thrust::device_vector<Intersection> intersections;
    for (deform = 0; deform < 2; deform++) {
        intersections.clear();
        for (int i = 0; i < MAX_SEPARATION_ITERATION; i++) {
            thrust::device_vector<Intersection> newIntersections = std::move(findIntersections(clothBvhs, obstacleBvhs, faces));
            if (newIntersections.empty()) {
                success = true;
                break;
            }

            intersections.insert(intersections.end(), newIntersections.begin(), newIntersections.end());
            Optimization* optimization = new SeparationOptimization(intersections, magic->collisionThickness, deform, obstacleArea);
            optimization->solve();
            delete optimization;

            updateClothFaceGeometries();
            updateBvhs(clothBvhs);
            if (deform == 1) {
                updateObstacleFaceGeometries();
                updateBvhs(obstacleBvhs);
                obstacleArea *= 0.5f;
            }
        }
        if (success)
            break;
    }
    if (!success) {
        std::cerr << std::endl << "Separation step failed!" << std::endl;
        exit(1);
    }

    destroyBvhs(clothBvhs);
    destroyBvhs(obstacleBvhs);

    updateClothNodeGeometries();
    updateClothVelocities();
    if (deform == 1) {
        updateObstacleNodeGeometries();
        updateObstacleVelocities();
    }
}

void Simulator::updateClothNodeGeometries() {
    for (Cloth* cloth : cloths)
        cloth->getMesh()->updateNodeGeometries();
}

void Simulator::updateObstacleNodeGeometries() {
    for (Obstacle* obstacle : obstacles)
        obstacle->getMesh()->updateNodeGeometries();
}

void Simulator::updateClothFaceGeometries() {
    for (Cloth* cloth : cloths)
        cloth->getMesh()->updateFaceGeometries();
}

void Simulator::updateObstacleFaceGeometries() {
    for (Obstacle* obstacle : obstacles)
        obstacle->getMesh()->updateFaceGeometries();
}

void Simulator::updateClothVelocities() {
    for (Cloth* cloth : cloths)
        cloth->getMesh()->updateVelocities(dt);
}

void Simulator::updateObstacleVelocities() {
    for (Obstacle* obstacle : obstacles)
        obstacle->getMesh()->updateVelocities(dt);
}

void Simulator::updateRenderingData(bool rebind) {
    for (Cloth* cloth : cloths)
        cloth->getMesh()->updateRenderingData(rebind);
    for (Obstacle* obstacle : obstacles)
        obstacle->getMesh()->updateRenderingData(false);
}

void Simulator::simulateStep(bool offline) {
    if ((++nSteps) % frameSteps == 0)
        nFrames++;
    std::cout << "Frame [" << nFrames << "], Step [" << nSteps << "]:" << std::endl;

    updateTransformations();

    Timer timer;

    physicsStep();
    cudaDeviceSynchronize();
    std::cout << "Physics Step: " << timer.duration() << "s";
    timer.update();

    collisionStep();
    cudaDeviceSynchronize();
    std::cout << ", Collision Step: " << timer.duration() << "s";
    timer.update();

    if (nSteps % frameSteps == 0) {
        if (disabled.find("remeshing") == disabled.end())
            if (!gpu) {
                std::vector<std::vector<BackupFace>> faces(cloths.size());
                for (int i = 0; i < cloths.size(); i++)
                    faces[i] = std::move(cloths[i]->getMesh()->backupFaces());

                remeshingStep();
                cudaDeviceSynchronize();
                std::cout << ", Remeshing Step: " << timer.duration() << "s";
                timer.update();

                separationStep(faces);
                cudaDeviceSynchronize();
                std::cout << ", Separation Step: " << timer.duration() << "s";
                timer.update();
            } else {
                std::vector<thrust::device_vector<BackupFace>> faces(cloths.size());
                for (int i = 0; i < cloths.size(); i++)
                    faces[i] = std::move(cloths[i]->getMesh()->backupFacesGpu());

                remeshingStep();
                cudaDeviceSynchronize();
                std::cout << ", Remeshing Step: " << timer.duration() << "s";
                timer.update();

                separationStep(faces);
                cudaDeviceSynchronize();
                std::cout << ", Separation Step: " << timer.duration() << "s";
                timer.update();
            }

        if (!offline)
            updateRenderingData(true);
        else
            save();
    } else if (!offline)
        updateRenderingData(false);

    std::cout << std::endl;
}

void Simulator::replayStep() {
    if (nFrames == endFrame)
        return;

    nSteps += frameSteps;
    nFrames++;
    std::cout << "Frame [" << nFrames << "]" << std::endl;

    if (load()) {
        updateTransformations();
        for (Obstacle* obstacle : obstacles)
            obstacle->transform(transformations);
        updateRenderingData(true);
    }
}


void Simulator::bind() {
    for (Cloth* cloth : cloths)
        cloth->bind();
    for (Obstacle* obstacle : obstacles)
        obstacle->bind();
}

void Simulator::render() const {
    Vector3f lightDirection = renderer->getLightDirection();
    Vector3f cameraPosition = renderer->getCameraPosition();
    Matrix4x4f model = renderer->getModel();
    Matrix4x4f view = renderer->getView();
    Matrix4x4f projection = renderer->getProjection();

    for (const Cloth* cloth : cloths)
        cloth->render(model, view, projection, cameraPosition, lightDirection);

    for (const Obstacle* obstacle : obstacles)
        obstacle->render(model, view, projection, cameraPosition, lightDirection);
}

bool Simulator::load() {
    for (int i = 0; i < cloths.size(); i++) {
        std::string path = directory + "/cloth" + std::to_string(i) + "_frame" + std::to_string(nFrames) + ".obj";
        if (!std::filesystem::exists(path))
            return false;
    }

    for (int i = 0; i < cloths.size(); i++) {
        std::string path = directory + "/cloth" + std::to_string(i) + "_frame" + std::to_string(nFrames) + ".obj";
        cloths[i]->load(path);
    }
    return true;
}

void Simulator::save() {
    for (int i = 0; i < cloths.size(); i++) {
        cloths[i]->save(directory + "/cloth" + std::to_string(i) + "_frame" + std::to_string(nFrames) + ".obj", json["cloths"][i]);
    }

    if (exportObstacles) {
        for (int i = 0; i < obstacles.size(); i++) {
            obstacles[i]->save(directory + "/obstacle" + std::to_string(i) + "_frame" + std::to_string(nFrames) + ".obj");
        }
    }

    std::ofstream fout(directory + "/config.json");
    fout << json;
    fout.close();
}

int Simulator::lastFrame() const {
    int ans = 0;
    bool flag;
    do {
        ans++;
        flag = true;
        for (int i = 0; i < cloths.size(); i++)
            if (!std::filesystem::exists(directory + "/cloth" + std::to_string(i) + "_frame" + std::to_string(ans) + ".obj")) {
                flag = false;
                break;
            }
    } while (flag);

    return ans - 1;
}

bool Simulator::finished() const {
    return nSteps * dt >= endTime || nFrames >= endFrame;
}

void Simulator::simulate() {
    if (disabled.find("remeshing") == disabled.end())
        if (!gpu) {
            std::vector<std::vector<BackupFace>> faces(cloths.size());
            for (int i = 0; i < cloths.size(); i++)
                faces[i] = std::move(cloths[i]->getMesh()->backupFaces());

            remeshingStep();
            separationStep(faces);
        } else {
            std::vector<thrust::device_vector<BackupFace>> faces(cloths.size());
            for (int i = 0; i < cloths.size(); i++)
                faces[i] = std::move(cloths[i]->getMesh()->backupFacesGpu());

            remeshingStep();
            separationStep(faces);
        }
    bind();

    while (!glfwWindowShouldClose(renderer->getWindow()) && !finished()) {
        glClearColor(1.0f, 1.0f, 1.0f, 1.0f);
        glClear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT);

        render();
        if (!renderer->getPause())
            simulateStep(false);

        glfwSwapBuffers(renderer->getWindow());
        glfwPollEvents();
    }
}

void Simulator::simulateOffline() {
    if (!std::filesystem::is_directory(directory))
        std::filesystem::create_directories(directory);

    if (disabled.find("remeshing") == disabled.end())
        if (!gpu) {
            std::vector<std::vector<BackupFace>> faces(cloths.size());
            for (int i = 0; i < cloths.size(); i++)
                faces[i] = std::move(cloths[i]->getMesh()->backupFaces());

            remeshingStep();
            separationStep(faces);
        } else {
            std::vector<thrust::device_vector<BackupFace>> faces(cloths.size());
            for (int i = 0; i < cloths.size(); i++)
                faces[i] = std::move(cloths[i]->getMesh()->backupFacesGpu());

            remeshingStep();
            separationStep(faces);
        }
    save();

    while (!finished())
        simulateStep(true);
}

void Simulator::resume() {
    nFrames = lastFrame();
    nSteps = nFrames * frameSteps;
    updateTransformations();
    for (Obstacle* obstacle : obstacles)
        obstacle->transform(transformations);
    bind();

    while (!glfwWindowShouldClose(renderer->getWindow()) && !finished()) {
        glClearColor(1.0f, 1.0f, 1.0f, 1.0f);
        glClear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT);

        render();
        if (!renderer->getPause())
            simulateStep(false);

        glfwSwapBuffers(renderer->getWindow());
        glfwPollEvents();
    }
}

void Simulator::resumeOffline() {
    nFrames = lastFrame();
    nSteps = nFrames * frameSteps;
    updateTransformations();
    for (Obstacle* obstacle : obstacles)
        obstacle->transform(transformations);

    while (!finished())
        simulateStep(true);
}

void Simulator::replay() {
    endFrame = lastFrame();
    load();
    bind();

    while (!glfwWindowShouldClose(renderer->getWindow())) {
        auto t0 = std::chrono::high_resolution_clock::now();

        glClearColor(1.0f, 1.0f, 1.0f, 1.0f);
        glClear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT);

        render();
        if (!renderer->getPause())
            replayStep();

        glfwSwapBuffers(renderer->getWindow());
        glfwPollEvents();

        for (Timer timer; timer.duration() < frameTime; );
    }
}

void Simulator::start() {
    switch (mode) {
    case Simulate:
        simulate();
        break;
    case SimulateOffline:
        simulateOffline();
        break;
    case Resume:
        resume();
        break;
    case ResumeOffline:
        resumeOffline();
        break;
    case Replay:
        replay();
        break;
    }
}