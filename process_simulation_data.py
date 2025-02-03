import os
import json
import numpy as np
from tqdm import tqdm
import logging
import re
import shutil
import random
from concurrent.futures import ThreadPoolExecutor, as_completed

random.seed(42)  # Use any fixed seed value for repeatability

# Set up logging
logging.basicConfig(level=logging.ERROR, format='%(asctime)s - %(levelname)s - %(message)s')

SPLITS = {
    'train': 0.8,
    'valid': 0.1,
    'test': 0.1
}

MAX_WORKERS = os.cpu_count() or 4  # Use all available CPU cores or 4 if can't determine

def read_obj_file(file_path):
    vertices = []
    faces = []
    try:
        with open(file_path, 'r') as f:
            for line in f:
                if line.startswith('v '):
                    _, x, y, z = line.split()
                    vertices.append([float(x), float(y), float(z)])
                elif line.startswith('f '):
                    _, v1, v2, v3 = line.split()
                    # OBJ files are 1-indexed, so we subtract 1 to convert to 0-indexed
                    faces.append([int(v1.split('/')[0])-1, int(v2.split('/')[0])-1, int(v3.split('/')[0])-1])
        return np.array(vertices), np.array(faces)
    except Exception as e:
        logging.error(f"Error reading OBJ file {file_path}: {e}")
        return np.array([]), np.array([])

def read_config_file(file_path):
    try:
        with open(file_path, 'r') as f:
            config = json.load(f)
        return config
    except Exception as e:
        logging.error(f"Error reading config file {file_path}: {e}")
        return {}

def find_file(folder, filename):
    for file in os.listdir(folder):
        if file.lower() == filename.lower():
            return os.path.join(folder, file)
    return None

def extract_frame_number(filename):
    match = re.search(r'frame(\d+)', filename)
    if match:
        return int(match.group(1))
    logging.error(f"Could not extract frame number from filename: {filename}")
    return None

def process_simulation(sim_folder, output_folder, dataset_type, new_sim_number):
    try:
        logging.info(f"Processing simulation folder: {sim_folder}")
        
        config_path = os.path.join(sim_folder, 'config.json')
        config = read_config_file(config_path)
        if not config:
            raise ValueError(f"Failed to read config file for {sim_folder}")

        handles = config.get('handles', [])
        handle_vertices = set()
        for handle in handles:
            handle_vertices.update(handle.get('nodes', []))

        original_mesh_path = os.path.join(sim_folder, 'square32.obj')
        original_mesh, original_faces = read_obj_file(original_mesh_path)
        if original_mesh.size == 0:
            raise ValueError(f"Failed to read original mesh file: {original_mesh_path}")

        # Get the node count (number of vertices in the mesh)
        node_count = len(original_mesh)

        # Check if obstacles are defined in the config
        obstacles = config.get('obstacles', [])
        has_obstacles = len(obstacles) > 0

        if has_obstacles:
            obstacle_mesh_filename = os.path.basename(obstacles[0]['mesh'])
            obstacle_mesh_path = find_file(sim_folder, obstacle_mesh_filename)
            if obstacle_mesh_path:
                obstacle_mesh, _ = read_obj_file(obstacle_mesh_path)
                if obstacle_mesh.size == 0:
                    logging.warning(f"Obstacle mesh exists but failed to read for {sim_folder}")
                    has_obstacles = False
            else:
                logging.warning(f"Obstacle mesh file not found in {sim_folder}")
                has_obstacles = False

        frame_files = [f for f in os.listdir(sim_folder) if f.startswith('cloth0_frame') and f.endswith('.obj')]
        if not frame_files:
            raise ValueError(f"No frame files found in {sim_folder}")

        if dataset_type == 'train':
            sim_output_folder = output_folder
        else:
            sim_output_folder = os.path.join(output_folder, f'sim_{new_sim_number:04d}')
        os.makedirs(sim_output_folder, exist_ok=True)

        for frame_file in sorted(frame_files, key=lambda x: extract_frame_number(x)):
            frame_number = extract_frame_number(frame_file)
            if frame_number is None:
                continue
            
            cloth_frame_path = os.path.join(sim_folder, frame_file)
            cloth_frame, _ = read_obj_file(cloth_frame_path)
            if cloth_frame.size == 0:
                logging.warning(f"Failed to read cloth frame {frame_file} for {sim_folder}")
                continue

            obstacle_frame_path = os.path.join(sim_folder, f'obstacle0_frame{frame_number}.obj') if has_obstacles else None
            if has_obstacles and obstacle_frame_path and os.path.exists(obstacle_frame_path):
                obstacle_frame, _ = read_obj_file(obstacle_frame_path)
                if obstacle_frame.size == 0:
                    logging.warning(f"Failed to read obstacle frame for frame {frame_number} in {sim_folder}")
                    has_obstacles = False  # Disable obstacle processing if reading fails

            output_lines = ["# Node features (Format: node_id, world_x, world_y, world_z, mesh_x, mesh_y, node_type)"]

            for i, (world_pos, original_pos) in enumerate(zip(cloth_frame, original_mesh)):
                node_type = 1 if i in handle_vertices else 0
                output_lines.append(f"{i}, {world_pos[0]}, {world_pos[1]}, {world_pos[2]}, {original_pos[0]}, {original_pos[1]}, {node_type}")

            if has_obstacles and 'obstacle_frame' in locals():
                for i, world_pos in enumerate(obstacle_frame, start=len(cloth_frame)):
                    output_lines.append(f"{i}, {world_pos[0]}, {world_pos[1]}, {world_pos[2]}, {world_pos[0]}, {world_pos[1]}, 2")

            output_lines.append("# Face features (Format: face_id, vertex1_id, vertex2_id, vertex3_id)")
            for i, face in enumerate(original_faces):
                output_lines.append(f"{i}, {face[0]}, {face[1]}, {face[2]}")

            if dataset_type == 'train':
                output_file = os.path.join(sim_output_folder, f"sim_{new_sim_number:03d}_frame_{frame_number:03d}.txt")
            else:
                output_file = os.path.join(sim_output_folder, f"frame_{frame_number:04d}.txt")
            with open(output_file, 'w') as f:
                f.write('\n'.join(output_lines))
        
        logging.info(f"Finished processing {sim_folder}")
        return True
    except Exception as e:
        logging.error(f"Error processing simulation {sim_folder}: {str(e)}")
        return False

def process_dataset(sim_folders, base_folder, output_folder, dataset_type):
    with ThreadPoolExecutor(max_workers=MAX_WORKERS) as executor:
        futures = []
        for i, sim_folder in enumerate(sim_folders):
            future = executor.submit(process_simulation, os.path.join(base_folder, sim_folder), output_folder, dataset_type, i)
            futures.append(future)
        
        for future in tqdm(as_completed(futures), total=len(futures), desc=f"Processing {dataset_type} simulations"):
            future.result()  # This will raise any exceptions that occurred during processing

def is_simulation_complete(sim_folder, expected_frames):
    try:
        config_path = os.path.join(sim_folder, 'config.json')
        if not os.path.exists(config_path):
            logging.error(f"Missing config.json in {sim_folder}")
            return False
            
        if not os.path.exists(os.path.join(sim_folder, 'square32.obj')):
            logging.error(f"Missing square32.obj in {sim_folder}")
            return False
            
        frame_files = [f for f in os.listdir(sim_folder) if f.startswith('cloth0_frame') and f.endswith('.obj')]
        obstacle_files = [f for f in os.listdir(sim_folder) if f.startswith('obstacle0_frame') and f.endswith('.obj')]

        if len(frame_files) != expected_frames:
            logging.error(f"Incomplete frame files in {sim_folder}: Found {len(frame_files)}, expected {expected_frames}")
            return False

        frame_numbers = sorted([extract_frame_number(f) for f in frame_files])
        expected_numbers = list(range(expected_frames))
        
        if frame_numbers != expected_numbers:
            logging.error(f"Frame number mismatch in {sim_folder}: Found {frame_numbers}, expected {expected_numbers}")
            return False

        return True
    except Exception as e:
        logging.error(f"Error checking simulation completeness for {sim_folder}: {str(e)}")
        return False


def process_all_simulations(base_folder, output_folder):
    logging.info(f"Checking base folder: {base_folder}")
    if not os.path.exists(base_folder):
        logging.error(f"Base folder does not exist: {base_folder}")
        return

    draping_sphere_folder = output_folder
    os.makedirs(draping_sphere_folder, exist_ok=True)

    # Get all simulation folders
    sim_folders = [f for f in os.listdir(base_folder) if f.startswith('sim_results_')]
    if not sim_folders:
        logging.error(f"No simulation folders found in {base_folder}")
        return

    # Determine expected number of frames and node count from the first complete simulation
    expected_frames = None
    node_count = None
    for sim_folder in sim_folders:
        full_path = os.path.join(base_folder, sim_folder)
        frame_files = [f for f in os.listdir(full_path) if f.startswith('cloth0_frame') and f.endswith('.obj')]
        if len(frame_files) > 0:
            expected_frames = len(frame_files)

            # Read the first frame to determine node count
            first_frame_path = os.path.join(full_path, frame_files[0])
            first_frame_vertices, _ = read_obj_file(first_frame_path)
            node_count = len(first_frame_vertices)

            break

    if expected_frames is None or node_count is None:
        logging.error("Could not determine expected number of frames or node count")
        return

    # Filter for complete simulations
    complete_sims = []
    for sim_folder in tqdm(sim_folders, desc="Checking simulation completeness"):
        full_path = os.path.join(base_folder, sim_folder)
        if is_simulation_complete(full_path, expected_frames):
            complete_sims.append(sim_folder)

    logging.info(f"Found {len(complete_sims)} complete simulations out of {len(sim_folders)} total")
    
    if not complete_sims:
        logging.error("No complete simulations found")
        return

    # Process only complete simulations
    random.shuffle(complete_sims)
    total_sims = len(complete_sims)
    train_count = int(total_sims * SPLITS['train'])
    valid_count = int(total_sims * SPLITS['valid'])
    test_count = total_sims - train_count - valid_count

    splits = {
        'train': complete_sims[:train_count],
        'valid': complete_sims[train_count:train_count+valid_count],
        'test': complete_sims[train_count+valid_count:]
    }

    # Process datasets
    training_phat_folder = os.path.join(draping_sphere_folder, 'training_phat')
    os.makedirs(training_phat_folder, exist_ok=True)
    process_dataset(splits['train'], base_folder, training_phat_folder, 'train')

    for dataset_type in ['valid', 'test']:
        dataset_folder = os.path.join(draping_sphere_folder, f'{dataset_type}_sims')
        os.makedirs(dataset_folder, exist_ok=True)
        process_dataset(splits[dataset_type], base_folder, dataset_folder, dataset_type)

    # Generate meta.json with the verified frame count and node count
    meta = {
        "trajectory_length": expected_frames,
        "features": {
            "world_pos": {
                "shape": [expected_frames, node_count, 3],
                "dtype": "float32",
                "type": "dynamic"
            },
            "prev|world_pos": {
                "shape": [expected_frames, node_count, 3],
                "dtype": "float32",
                "type": "dynamic"
            },
            "node_type": {
                "shape": [expected_frames, node_count, 1],
                "dtype": "int64",
                "type": "static"
            },
            "cells": {
                "shape": [expected_frames, len(first_frame_vertices), 3],
                "dtype": "int64",
                "type": "dynamic_varlen"
            },
            "mesh_pos": {
                "shape": [expected_frames, node_count, 2],
                "dtype": "float32",
                "type": "dynamic"
            }
        }
    }

    with open(os.path.join(draping_sphere_folder, 'meta.json'), 'w') as f:
        json.dump(meta, f, indent=4)

    print(f"Processing completed. Results saved in: {draping_sphere_folder}")

    
if __name__ == "__main__":
    base_folder = "/home/jjdunlop/ClothSimulator/output/PairedSphereDraping32/sphereIso32"
    output_folder = "/home/jjdunlop/PairedSphereDraping32/sphereIso32"
    process_all_simulations(base_folder, output_folder)
