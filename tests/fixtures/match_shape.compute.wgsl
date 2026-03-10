var<private> global_invocation_id: vec3u;
var<private> local_invocation_id: vec3u;
var<private> workgroup_id: vec3u;
var<private> num_workgroups: vec3u;
var<private> local_invocation_index: u32;

struct Shape {
    tag: i32,
    __Circle_radius: f32,
    __Rect_width: f32,
    __Rect_height: f32,
};

fn Circle(arg_0: f32) -> Shape {
    var __result: Shape;
    __result.tag = 0;
    __result.__Circle_radius = arg_0;
    return __result;
}

fn Rect(arg_0: f32, arg_1: f32) -> Shape {
    var __result: Shape;
    __result.tag = 1;
    __result.__Rect_width = arg_0;
    __result.__Rect_height = arg_1;
    return __result;
}

fn Point() -> Shape {
    var __result: Shape;
    __result.tag = 2;
    return __result;
}

fn __match_0(__match_value: Shape) -> f32 {
    if (__match_value.tag == 0 && true) {
        return 3.14159 * __match_value.__Circle_radius * __match_value.__Circle_radius;
    } else {
        if (__match_value.tag == 1 && true && true) {
            return __match_value.__Rect_width * __match_value.__Rect_height;
        } else {
            if (__match_value.tag == 2) {
                return 0.0;
            } else {
                return 0.0;
            }
        }
    }
    return 0.0;
}

fn area(shape: Shape) -> f32 {
    return __match_0(shape);
}

fn __zwgsl_compute_main() {
    var value: f32 = area(Circle(2.0));
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
