#!/bin/bash
set -e
# Set ROS 2 distribution as a variable
ROS_DISTRO="jazzy"
# Source ROS 2 setup
source /opt/ros/$ROS_DISTRO/setup.bash

# Install system dependencies for MongoDB and PCL
apt-get update && apt-get install -y \
    gnupg \
    curl \
    libpcap-dev \
    lsb-release

# Install MongoDB (matches installed version: 7.0.37)
curl -fsSL https://www.mongodb.org/static/pgp/server-7.0.asc | \
    gpg -o /usr/share/keyrings/mongodb-server-7.0.gpg \
    --dearmor
echo "deb [ arch=amd64,arm64 signed-by=/usr/share/keyrings/mongodb-server-7.0.gpg ] https://repo.mongodb.org/apt/ubuntu jammy/mongodb-org/7.0 multiverse" | \
    tee /etc/apt/sources.list.d/mongodb-org-7.0.list
apt-get update && apt-get install -y mongodb-org

# Start and enable MongoDB service
# Note: systemctl might not work in all Docker environments, so we'll add error handling
systemctl start mongod || echo "Warning: Could not start MongoDB service. This is expected in some Docker environments."
systemctl enable mongod || echo "Warning: Could not enable MongoDB service. This is expected in some Docker environments."

# Add Gazebo/OSRF repo (needed for gz-msgs10 and other Gazebo Harmonic libs
# required by mycobot_gazebo / ros-gz packages)
echo "Adding Gazebo/OSRF apt repo..."
curl -fsSL https://packages.osrfoundation.org/gazebo.gpg -o /usr/share/keyrings/pkgs-osrf-archive-keyring.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/pkgs-osrf-archive-keyring.gpg] http://packages.osrfoundation.org/gazebo/ubuntu-stable $(lsb_release -cs) main" | \
    tee /etc/apt/sources.list.d/gazebo-stable.list > /dev/null
apt-get update
apt-get install -y gz-harmonic=1.0.0-1~noble

# Navigate to the workspace
cd /root/ros2_ws/src

# Install warehouse_ros_mongo if not already present
if [ ! -d "warehouse_ros_mongo" ]; then
    git clone https://github.com/moveit/warehouse_ros_mongo.git -b ros2
    cd warehouse_ros_mongo/
    git reset --hard 32f8fc5dd245077b9c09e93efc8625b9f599f271
    cd ..
fi

# Install MoveIt Task Constructor if not already present
# Pinned to current workspace commit (branch: ros2)
if [ ! -d "moveit_task_constructor" ]; then
    git clone https://github.com/moveit/moveit_task_constructor.git -b ros2
    cd moveit_task_constructor
    git reset --hard f16c557cb3ec9acffa0579f8d7345c26b1491e95
    cd ..
fi

# Navigate back to the workspace root
cd /root/ros2_ws

# Install ROS2 dependencies for all packages
echo "Installing ROS 2 dependencies..."
rosdep update
rosdep install -i --from-path src --rosdistro $ROS_DISTRO -y

# Now apply remaining fixes after dependencies are installed
# Fix storage.cpp
echo "Fixing storage.cpp..."
cd /root/ros2_ws/src/moveit_task_constructor
if [ -f core/src/storage.cpp ]; then
    # Create backup
    cp core/src/storage.cpp core/src/storage.cpp.backup
    # Replace the four lines with the new line using sed
    sed -i '/if (this->end()->scene()->getParent() == this->start()->scene())/,+3c\    this->end()->scene()->getPlanningSceneDiffMsg(t.scene_diff);' core/src/storage.cpp || echo "Warning: Could not modify storage.cpp"
fi

# NOTE: cartesian_path.cpp no longer needs patching at this commit.
# The file already uses moveit::core::CartesianPrecision natively
# (JumpThreshold::relative() fix is obsolete / already upstreamed).

cd /root/ros2_ws

# Fix PCL warning - this needs to come after rosdep install
echo "Fixing PCL warnings..."
find /usr/include/pcl* -path "*/sample_consensus/impl/sac_model_plane.hpp" -exec sed -i 's/^\(\s*\)PCL_ERROR ("\[pcl::SampleConsensusModelPlane::isSampleGood\] Sample points too similar or collinear!\\n");/\1\/\/ PCL_ERROR ("[pcl::SampleConsensusModelPlane::isSampleGood] Sample points too similar or collinear!\\n");/' {} \;

# Build the packages
echo "Building packages..."
# First build without the problematic package
colcon build --packages-skip mycobot_mtc_pick_place_demo
source install/setup.bash

# Then build the problematic package with warning suppression
colcon build --packages-select mycobot_mtc_pick_place_demo --cmake-args -Wno-dev
source install/setup.bash

# Final build of everything
colcon build 

echo "Workspace setup completed!"
