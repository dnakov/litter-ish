libish_embed = library('ish_embed',
    ['ish_embed.c'],
    include_directories: includes,
)

ish_embed = declare_dependency(
    link_with: [libish_embed],
    include_directories: includes,
)

if not meson.is_cross_build()
    executable('smoke_host',
        ['tests/smoke_host.c'],
        dependencies: [ish, ish_embed])
endif
