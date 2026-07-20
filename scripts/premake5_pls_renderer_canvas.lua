local runtime_dir = os.getenv('RIVE_RUNTIME_DIR')
assert(runtime_dir, 'RIVE_RUNTIME_DIR must be set by scripts/build.rive.sh')

-- The renderer premake already gates its ORE sources and Metal backend on
-- this option, but its standalone entry point does not register the option.
-- Register it in the Apple package wrapper so the fork can opt into the
-- upstream capability without modifying the rive-runtime submodule.
newoption({
    trigger = 'with_rive_canvas',
    description = 'Compiles in the Ore GPU abstraction layer.',
})

-- Upstream's renderer entry point uses RIVE_CANVAS for the RenderCanvas
-- implementation and RIVE_ORE for the Ore backend, but only defines the
-- latter. Keep both sides of that public renderer capability enabled.
filter({ 'options:with_rive_canvas' })
do
    defines({ 'RIVE_CANVAS' })
end
filter({})

dofile(path.join(runtime_dir, 'renderer', 'premake5_pls_renderer.lua'))
