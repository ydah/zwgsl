var<private> global_invocation_id: vec3u;
var<private> local_invocation_id: vec3u;
var<private> workgroup_id: vec3u;
var<private> num_workgroups: vec3u;
var<private> local_invocation_index: u32;

struct Shape {
    tag: i32,
    _Circle_radius: f32,
    _Rect_width: f32,
    _Rect_height: f32,
}

fn Circle(arg_0: f32) -> Shape {
    var _result: Shape;
    _result.tag = 0;
    _result._Circle_radius = arg_0;
    return _result;
}

fn Rect(arg_0: f32, arg_1: f32) -> Shape {
    var _result: Shape;
    _result.tag = 1;
    _result._Rect_width = arg_0;
    _result._Rect_height = arg_1;
    return _result;
}

fn Point() -> Shape {
    var _result: Shape;
    _result.tag = 2;
    return _result;
}

fn _match_0(_match_value: Shape) -> f32 {
    switch (_match_value.tag) {
        case 0: {
            if (_match_value.tag == 0 && true) {
                return 3.14159 * _match_value._Circle_radius * _match_value._Circle_radius;
            } else {
                return 0.0;
            }
        }
        case 1: {
            if (_match_value.tag == 1 && true && true) {
                return _match_value._Rect_width * _match_value._Rect_height;
            } else {
                return 0.0;
            }
        }
        case 2: {
            if (_match_value.tag == 2) {
                return 0.0;
            } else {
                return 0.0;
            }
        }
        default: {
            return 0.0;
        }
    }
}

fn area(shape: Shape) -> f32 {
    return _match_0(shape);
}

fn _zwgsl_compute_main() {
    let value: f32 = area(Circle(2.0));
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
    _zwgsl_compute_main();
}
