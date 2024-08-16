znap function updateDockerHostEnv() {
  command -v podman && DOCKER_HOST=$(podman machine inspect --format '{{.ConnectionInfo.PodmanSocket.Path}}')
}

command -v podman && DOCKER_HOST=$(podman machine inspect --format '{{.ConnectionInfo.PodmanSocket.Path}}')