import os

APK_REPOSITORIES = [
    ('v3.21', 'main'),
    ('v3.21', 'community'),
]
GUEST_ARCH = os.environ.get('GUEST_ARCH', 'arm64')

repos_file = []
if GUEST_ARCH == 'arm64':
    # ARM64 guest: use official Alpine Linux CDN for aarch64 packages.
    for version, repo in APK_REPOSITORIES:
        repos_file.append(f'https://dl-cdn.alpinelinux.org/alpine/{version}/{repo}')
else:
    raise SystemExit(f'unsupported guest architecture: {GUEST_ARCH}')

with open(os.path.join(os.environ['BUILT_PRODUCTS_DIR'], os.environ['CONTENTS_FOLDER_PATH'], 'repositories.txt'), 'w') as f:
    for line in repos_file:
        print(line, file=f)
