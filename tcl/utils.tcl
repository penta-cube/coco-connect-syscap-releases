namespace eval ::coco_syscap_utils {}

proc ::coco_syscap_utils::json_escape {text} {
    set escaped [string map [list "\\" "\\\\" "\"" "\\\"" "\b" "\\b" "\f" "\\f" "\n" "\\n" "\r" "\\r" "\t" "\\t"] $text]
    set out ""
    foreach ch [split $escaped ""] {
        if {$ch eq ""} {
            continue
        }
        scan $ch %c code
        if {$code < 32} {
            append out [format "\\u%04x" $code]
        } else {
            append out $ch
        }
    }
    return $out
}

proc ::coco_syscap_utils::json_quote {text} {
    return "\"[json_escape $text]\""
}

proc ::coco_syscap_utils::json_bool {value} {
    expr {$value ? "true" : "false"}
}

proc ::coco_syscap_utils::json_number {value} {
    return $value
}

proc ::coco_syscap_utils::json_null {} {
    return "null"
}

proc ::coco_syscap_utils::json_field_string {key value} {
    return "[json_quote $key]:[json_quote $value]"
}

proc ::coco_syscap_utils::json_field_number {key value} {
    return "[json_quote $key]:[json_number $value]"
}

proc ::coco_syscap_utils::json_field_bool {key value} {
    return "[json_quote $key]:[json_bool $value]"
}

proc ::coco_syscap_utils::json_field_json {key json_value} {
    return "[json_quote $key]:$json_value"
}

proc ::coco_syscap_utils::json_object_from_pairs {pairs} {
    return "\{[join $pairs ,]\}"
}

proc ::coco_syscap_utils::json_array_from_values {values} {
    return "\[[join $values ,]\]"
}

proc ::coco_syscap_utils::json_success {data_json} {
    return [json_object_from_pairs [list \
        [json_field_bool ok 1] \
        [json_field_json data $data_json]]]
}

proc ::coco_syscap_utils::json_error {code message {details_json ""}} {
    if {$details_json eq ""} {
        set details_json [json_null]
    }
    set error_json [json_object_from_pairs [list \
        [json_field_string code $code] \
        [json_field_string message $message] \
        [json_field_json details $details_json]]]
    return [json_object_from_pairs [list \
        [json_field_bool ok 0] \
        [json_field_json error $error_json]]]
}

proc ::coco_syscap_utils::looks_like_json {text} {
    set trimmed [string trim $text]
    expr {[string length $trimmed] >= 2 && [string index $trimmed 0] eq "\{" && [string index $trimmed end] eq "\}"} 
}

proc ::coco_syscap_utils::ensure_error_json {message {code "bridge_error"}} {
    if {[looks_like_json $message]} {
        return $message
    }
    return [json_error $code $message]
}
