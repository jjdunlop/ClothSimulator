import numpy as np
import matplotlib.pyplot as plt

def generate_mot_file_with_orientation(num_frames, start_position, end_position, filename):
    """
    Generates a .mot file with eased motion and constant orientation for each frame.

    Parameters:
    - num_frames: Number of frames for the motion.
    - start_position: Starting position (z-coordinate).
    - end_position: Ending position (z-coordinate).
    - filename: The name of the output .mot file.
    """
    # Generate time points
    t = np.linspace(0, np.pi, num_frames)
    # Calculate positions using a sinusoidal easing function
    positions = start_position + (end_position - start_position) * (0.5 - 0.5 * np.cos(t))

    # Define a constant orientation (no rotation quaternion)
    orientation = (1, 0, 0, 0)

    # Write to .mot file
    with open(filename, 'w') as file:
        file.write(f"NumFrames: {num_frames}\n")
        file.write("node[0] position\n")  # Assuming motion for node[0]
        for pos in positions:
            file.write(f"0 0 {pos:.6f}\n")
        file.write("node[0] orientation\n")  # Assuming orientation for node[0]
        for _ in range(num_frames):
            file.write(f"{orientation[0]} {orientation[1]} {orientation[2]} {orientation[3]}\n")

    # Plotting the motion
    plt.figure(figsize=(10, 6))
    plt.plot(np.arange(num_frames), positions, label='Node[0] z-position', marker='o')
    plt.title('Node Movement Over Time with Easing')
    plt.xlabel('Frame Number')
    plt.ylabel('Z Position')
    plt.grid(True)
    plt.legend()
    plt.show()

# Parameters for the motion file
num_frames = 50  # Total number of frames
start_position = 0  # Starting z-position
end_position = -0.5  # Ending z-position
filename = "test.mot"  # Output file name

# Generate the .mot file and plot the motion
generate_mot_file_with_orientation(num_frames, start_position, end_position, filename)
