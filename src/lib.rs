use proxy_wasm::traits::{Context, HttpContext, RootContext};
use proxy_wasm::types::Action;

struct Root;
impl Context for Root {}
impl RootContext for Root {
    fn create_http_context(&self, _id: u32) -> Option<Box<dyn HttpContext>> {
        Some(Box::new(Filter))
    }
}

struct Filter;
impl Context for Filter {}
impl HttpContext for Filter {
    fn on_http_response_headers(&mut self, _num: usize, _eos: bool) -> Action {
        // Add a header to every response
        let _ = proxy_wasm::hostcalls::set_http_response_header("x-wasm-custom", Some("FOO"));
        Action::Continue
    }
}

proxy_wasm::main! {{
    proxy_wasm::set_root_context(|_vm_id| Box::new(Root));
}}
