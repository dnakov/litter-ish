import os

APK_REPOSITORIES = [
    ('v3.21', 'main'),
    ('v3.21', 'community'),
]

repos_file = []
for version, repo in APK_REPOSITORIES:
    repos_file.append(f'https://dl-cdn.alpinelinux.org/alpine/{version}/{repo}')

with open(os.path.join(os.environ['BUILT_PRODUCTS_DIR'], os.environ['CONTENTS_FOLDER_PATH'], 'repositories.txt'), 'w') as f:
    for line in repos_file:
        print(line, file=f)
