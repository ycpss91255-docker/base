// class: policy-refused go_mod_unsupported_syntax retract
module example.com/m
retract [v1.0.0, v1.1.0] // why
require a v1.0.0
