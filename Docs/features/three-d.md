# Image to 3D

Open **Images**, then select **Image to 3D**. Choose an image of one
object, select **Photo** or **Illustration or render**, then click **Generate 3D**.
Idol runs locally on Apple silicon. A seed makes repeated generations reproducible.

The first run downloads `speridlabs/idol` and its image encoders. Accept access to
[DINOv3](https://huggingface.co/facebook/dinov3-vith16plus-pretrain-lvd1689m) and
[FLUX.2](https://huggingface.co/black-forest-labs/FLUX.2-dev), and configure your
Hugging Face token in Developer before generating. Model downloads use Nativ's
configured Hugging Face cache. The encoders can require substantial storage.

The workspace submits `POST /v1/meshes`, polls `GET /v1/meshes/{id}`, then downloads
`GET /v1/meshes/{id}/content`. It uses 50 steps, guidance 3, and 262,144 splats.
The bundled runtime includes [MLX-VLM #2644](https://github.com/Blaizzy/mlx-vlm/pull/2644).

Completed objects, their input images, and camera metadata are kept in
`~/Library/Application Support/Nativ/3D`. **Save PLY** exports the splats;
**Show in Finder** opens their local folder. Generation continues when switching
workspaces, and all Nativ windows share the same 3D history. Keep Nativ and its
server running until generation completes; unfinished jobs cannot resume after
a restart.

Completed results open automatically in an interactive Metal Gaussian splat preview.
Drag to rotate, scroll or pinch to zoom, and use **Reset view** to restore the initial
camera. Selecting an object in **Recent objects** opens its saved reconstruction.
Rendering and camera controls run locally without a viewer dependency.

PLY contains splats rather than a triangle mesh; standard mesh viewers may not
display it correctly. GLB/OBJ conversion, video export, and multi-image conditioning
are not included.
