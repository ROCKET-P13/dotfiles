; extends

(object
	(pair
	  key: (property_identifier) @object_property_key
	  )
  )

(return_statement
	(class 
	  (class_heritage
		(identifier) @class_extends
	  )
	)
)


(call_expression
	(member_expression 
		(identifier) @private_class_property
	)
)


(object
  (shorthand_property_identifier) @shorthand_property_identifier 
)



(member_expression
	object: (identifier) 
	property: (property_identifier) 
	@property_reference
	(#set! "priority" 110)
)


(member_expression
	object: (this) 
	property: (private_property_identifier) 
	@property_reference
	(#set! "priority" 110)
)

(member_expression
	property: (property_identifier) @property_reference
	(#set! "priority" 110)
)


(call_expression
	function: (member_expression
		object: (identifier) 
		property: (property_identifier) @method_call
		(#set! "priority" 111)
	) 
)


(call_expression
	function: (member_expression
		property: (property_identifier) @testingg
		(#set! "priority" 111)
	) 
)

(call_expression
	function: (member_expression
		property: (private_property_identifier) @testingg
		(#set! "priority" 111)
	) 
)

(call_expression
 function: (member_expression
	  object: (member_expression ; [459, 38] - [459, 66]
		object: (this) ; [459, 38] - [459, 42]
		property: (private_property_identifier)) ; [459, 43] - [459, 66]
	  property: (property_identifier) @testingg
		(#set! "priority" 111)
	)
)

(new_expression ; [66, 33] - [66, 74]
	constructor: (member_expression ; [66, 37] - [66, 72]
	property: (property_identifier) @method_call
	  (#set! "priority" 111)
  )
)


; Operators
[";" ":" "," "." "="] @operator
[">" "<" "||" "!" "&&" "</"] @special_operator

; Function definitions
(function_declaration
  name: (identifier) @function)
(arrow_function
  "=>" @operator)

(jsx_attribute
  (property_identifier) @jsx.attr.name
  )

(jsx_opening_element
  "<" @jsx.tag.delimiter
  name: (identifier) @jsx.tag.name
  )
(jsx_opening_element
  ">" @jsx.tag.delimiter
  )

(jsx_closing_element
  ">" @jsx.tag.delimiter
  )
(jsx_closing_element
  "</" @jsx.tag.delimiter
  )

; Method calls
(call_expression
  function: (member_expression
    property: (property_identifier) @function.method))
(call_expression
  function: (identifier) @function.call)

; Class definitions
(class
  name: (identifier) @class.name
  )

(class_declaration
  name: (identifier) @class.name
  )


(member_expression
  object: (this) @class.this
  )

(call_expression
	function: (super) @class.super
  )


(assignment_expression
	left: (member_expression
		  property: (property_identifier) @const_arrow_function
		  (#set! "priority" 111)
		)
	right: (arrow_function)
  )

(assignment_expression
	left: (member_expression
		  property: (property_identifier) @const_arrow_function
		  (#set! "priority" 111)
		)
	right: (function_expression)
  )

; Keywords
"class" @keyword.class
"const" @keyword.const
"let" @keyword.let
"var" @keyword.var
"function" @keyword.function
"new" @keyword.new
"delete" @keyword.delete
"async" @keyword.async
