znap function updateDockerHostEnv() {
  command -v podman && DOCKER_HOST=$(podman machine inspect --format '{{.ConnectionInfo.PodmanSocket.Path}}')
}

# not needed when eval $(crc podman-env)
# command -v podman && DOCKER_HOST=$(podman machine inspect --format '{{.ConnectionInfo.PodmanSocket.Path}}')