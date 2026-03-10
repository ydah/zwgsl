var<private> global_invocation_id: vec3u;
var<private> local_invocation_id: vec3u;
var<private> workgroup_id: vec3u;
var<private> num_workgroups: vec3u;
var<private> local_invocation_index: u32;

fn __zwgsl_compute_main() {
    let transform: mat4x4f = mat4x4f(1.0);
    let value: vec4f = vec4f(1.0);
    let energy: f32 = dot(value, value);
}

@compute @workgroup_size(1)
fn main(
    @builtin(global_invocation_id) global_invocation_id_input: vec3u,
    @builtin(local_invocation_id) local_invocation_id_input: vec3u,
    @builtin(workgroup_id) workgroup_id_input: vec3u,
    @builtin(num_workgroups) num_workgroups_input: vec3u,
    @builtin(local_invocation_index) local_invocation_index_input: u32,
) {
    global_invocation_id = global_invocation_id_input;
    local_invocation_id = local_invocation_id_input;
    workgroup_id = workgroup_id_input;
    num_workgroups = num_workgroups_input;
    local_invocation_index = local_invocation_index_input;
    __zwgsl_compute_main();
}
