# 🗂Introduction

This is a GPU-based cloth simulator implemented by CUDA. The algorithm is based on [ARCSim](http://graphics.berkeley.edu/resources/ARCSim/).

### Changes
- Changed exporting to include obstacles.
- Introduced a new command line flag (--no-export-obstacles) to disable the export of obstacle data during simulations.
- Improved the naming convention for saved frame files, making it more intuitive and easier to manage.
- Adjusted the replay function to accommodate the new naming convention.

For example, I used this [plugin](https://github.com/neverhood311/Stop-motion-OBJ) to bring the OBJs into Blender 3.6.

[](https://github.com/jjdunlop/ClothSimulator/assets/66872523/34166f11-a1b1-44a7-8a7f-053b0324f1c9)

# 🛠 Setup
### Dependencies

- OpenGL
- GLAD (already in lib directory)
- GLFW
- jsoncpp
- Eigen
- CUDA

Note: If you're using Windows, vspkg is recommended to install dependencies.

### Build

Run the following command in this directory:

```key
mkdir build
cd build
cmake ..
make all
```

# 📑 Usage

The simulator has 5 different modes. All the command mentioned should be run in this directory. Drop the --gpu parameter if you want CPU simulation.

### Simulate

Simulate and display according to a configuration file.

Note: Currently, the simulate mode is not working due to an OpenGL issue.

```key
./build/ClothSimulator simulate [config_file] --gpu
```

For example:

```key
./build/ClothSimulator simulate conf/sphere.json --gpu
```

### Simulate (Offline)

Similar to simulate mode, but will save cloth mesh for every frame to output directory. You can also disable obstacle data export with the '--no-export-obstacles' flag.

```key
./build/ClothSimulator simulate_offline [config_file] [output_dir] --gpu [--no-export-obstacles]
```

For example:

```key
./build/ClothSimulator simulate_offline conf/sphere.json output/sphere --gpu [--no-export-obstacles]
```

### Resume

Resume and display a halted offline simulation.

```key
./build/ClothSimulator resume [output_dir] --gpu
```

### Resume (Offline)

Similar to resume mode, but will save cloth mesh for every frame to output directory. You can also disable obstacle data export with the '--no-export-obstacles' flag.

```key
./build/ClothSimulator resume_offline [output_dir] --gpu [--no-export-obstacles]
```

### Replay

Replay simulation result according to a output directiry. This mode has no GPU mode.

```key
./build/ClothSimulator replay [output_dir]
```

# 📬 Feedback
If you find any problems, feel free to raise an `Issue` or to contribute with a `Pull Request`!


# 📜 Credits

I am not the author of this code, I just made modifications. Full credits go to the original authors. The original GPU accelerated code can be found [here](https://github.com/Wajov/ClothSimulator).


If you use this code for a publication, make sure to cite the following papers:

>Rahul Narain, Armin Samii, and James F. O'Brien. "Adaptive Anisotropic Remeshing for Cloth Simulation". ACM Transactions on Graphics, 31(6):147:1–10, November 2012. Proceedings of ACM SIGGRAPH Asia 2012, Singapore.

>Rahul Narain, Tobias Pfaff, and James F. O'Brien. "Folding and Crumpling Adaptive Sheets". ACM Transactions on Graphics, 32(4):51:1–8, July 2013. Proceedings of ACM SIGGRAPH 2013, Anaheim.

>Tobias Pfaff, Rahul Narain, Juan Miguel de Joya, and James F. O'Brien. "Adaptive Tearing and Cracking of Thin Sheets". ACM Transactions on Graphics, 33(4):110:1–9, July 2014. Proceedings of ACM SIGGRAPH 2014, Vancouver.



# 👀  Samples

Here are some offline results:

![](samples/sphere.gif)

![](samples/sleeve.gif)

![](samples/dress-blue.gif)

![](samples/dress-yellow.gif)
