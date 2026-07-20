; extends

(member_expression
	; object: (identifier) 
	property: (property_identifier) 
	@property_reference
	(#set! "priority" 110)
)

function: (member_expression
	object: (identifier) 
	property: (property_identifier) 
	@method_call
	(#set! "priority" 120)
)

(object
  (shorthand_property_identifier) @shorthand_property_identifier 
)

(member_expression
	object: (this) 
	property: (property_identifier) 
	@property_reference
	(#set! "priority" 110)
)

object: (member_expression
	property: (property_identifier) 
	@property_reference
	(#set! "priority" 110)
)

(type_identifier) @function.builtin.typescript

(property_signature 
    name: (property_identifier) @property_reference
)

(enum_assignment 
    name: (property_identifier) @property_reference
)

(enum_declaration
	name: (identifier) @enum_name
  )

(public_field_definition
    (accessibility_modifier) 
	name: (property_identifier) @property_reference
)
