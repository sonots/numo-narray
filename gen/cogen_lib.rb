require "erb"

TMPL_DIR="template"

module PutERB
  def erb
    file = TMPL_DIR+"/#{@tmpl}.c"
    if $embed
      "\n"+ERB.new(File.read(file)).result(binding)
    else
      puts "\n/* ERB from #{file} */"
      ERB.new(File.read(file)).run(binding)
    end
  end
end

class Cast
  include PutERB
  INIT = []

  def self.c_function
    "nary_#{tp}_s_cast"
  end

  def initialize(tmpl,tpname,dtype,tpclass,macro)
    @tmpl=tmpl
    @tpname=tpname
    @dtype=dtype
    @tpclass=tpclass
    @macro=macro
    T[tmpl] = self
  end
  attr_reader :tmpl, :tpname, :dtype, :tpclass, :macro

  def c_function
    "nary_#{tp}_store_#{tpname}"
  end

  def c_iterator
    "iter_#{tp}_store_#{tpname}"
  end

  def result
    INIT << self
    erb
  end

  def condition
    "rb_obj_is_kind_of(obj,#{tpclass})"
  end
end

class CastNum < Cast
  def initialize(tmpl)
    @tmpl=tmpl
    @tpname="numeric"
    T[tmpl] = self
  end
  def condition
    "FIXNUM_P(obj) || TYPE(obj)==T_FLOAT || TYPE(obj)==T_BIGNUM || rb_obj_is_kind_of(obj,rb_cComplex)"
  end
end

class CastArray < Cast
  def initialize(tmpl)
    @tmpl=tmpl
    @tpname="array"
    T[tmpl] = self
  end
  def c_function
    "nary_#{tp}_#{tmpl}"
  end
  def condition
    "TYPE(obj)==T_ARRAY"
  end
  def result2
    erb
  end
end

# ----------------------------------------------------------------------

class Template
  include PutERB
  INIT = []
  OPMAP = {
    "add"=>"+", "sub"=>"-", "mul"=>"*", "div"=>"/",
    "mod"=>"%", "pow"=>"**", "minus"=>"-@", "plus"=>"+@",
    "and"=>"&",
    "or"=>"|",
    "xor"=>"^",
    "not"=>"~",
    "bit_and"=>"&",
    "bit_or"=>"|",
    "bit_xor"=>"^",
    "bit_not"=>"~"
  }

  def self.alias(dst,src)
    INIT << "rb_define_alias(cT, \"#{dst}\", \"#{src}\");"
  end

  def initialize(tmpl,op,hash={})
    @tmpl=tmpl
    @op=op
    hash.each do |k,v|
      name = k.to_s
      ivar = "@"+name
      instance_variable_set(ivar,v)
      define_singleton_method(name){instance_variable_get(ivar)}
    end
    T[tmpl] = self
  end
  attr_reader :op

  def c_instance_method
    "nary_#{tp}_#{op}"
  end

  def c_singleton_method
    "nary_#{tp}_s_#{op}"
  end

  def c_iterator
    "iter_#{tp}_#{op}"
  end

  def op_map
    OPMAP[op] || op
  end

  def id_op
    x = OPMAP[op] || op
    if x.size == 1
      "'#{x}'"
    else
      "id_#{op}"
    end
  end

  def def_singleton(n=0)
    INIT << "rb_define_singleton_method(cT, \"#{op}\", #{c_singleton_method}, #{n});"
    erb
  end

  def def_binary
    #INIT << "rb_define_singleton_method(cT, \"#{op}\", #{c_singleton_method}, 2);"
    INIT << "rb_define_method(cT, \"#{op_map}\", #{c_instance_method}, 1);"
    erb
  end

  def def_method(n=0)
    INIT << "rb_define_method(cT, \"#{op_map}\", #{c_instance_method}, #{n});"
    erb
  end

  def def_func
    erb
  end

  def def_math(n=1)
    INIT << "rb_define_singleton_method(mTM, \"#{op}\", #{c_singleton_method}, #{n});"
    erb
  end
end

# ----------------------------------------------------------------------

class Cogen

  def initialize
    @class_alias = []
    @upcast = []
  end

  attrs = %w[
    class_name
    ctype
    real_class_name
    real_ctype

    has_math
    is_bit
    is_int
    is_float
    is_real
    is_complex
    is_object
    is_comparable
  ]

  attrs.each do |attr|
    ivar = ("@"+attr).to_sym
    define_method(attr){|*a| attr_def(ivar,*a)}
  end

  def attr_def(ivar,arg=nil)
    if arg.nil?
      instance_variable_get(ivar)
    else
      instance_variable_set(ivar,arg)
    end
  end

  def type_name
    @type_name ||= class_name.downcase
  end
  alias tp type_name

  def type_var
    @type_var ||= "c"+class_name
  end

  def math_var
    @math_var ||= "m"+class_name+"Math"
  end

  def real_class_name(arg=nil)
    if arg.nil?
      @real_class_name ||= class_name
    else
      @real_class_name = arg
    end
  end

  def real_ctype(arg=nil)
    if arg.nil?
      @real_ctype ||= ctype
    else
      @real_ctype = arg
    end
  end

  def real_type_var
    @real_type_var ||= "c"+real_class_name
  end

  def real_type_name
    @real_type_name ||= real_class_name.downcase
  end

  def class_alias(*args)
    @class_alias.concat(args)
  end

  def upcast(c=nil,t="T")
    if c
      @upcast << "rb_hash_aset(hCast, c#{c}, c#{t});"
    else
      @upcast
    end
  end

  def upcast_rb(c,t="T")
    if c=="Integer"
      @upcast << "rb_hash_aset(hCast, rb_cFixnum, c#{t});"
      @upcast << "rb_hash_aset(hCast, rb_cBignum, c#{t});"
    else
      @upcast << "rb_hash_aset(hCast, rb_c#{c}, c#{t});"
    end
  end

  def def_singleton(ope,n=0)
    Template.new(ope,ope).def_singleton(n)
  end

  def def_method(tmpl,n=0)
    Template.new(tmpl,tmpl).def_method(n)
  end

  def binary(ope)
    Template.new("binary",ope).def_binary
  end

  def pow
    Template.new("pow","pow").def_binary
  end

  def unary(ope)
    Template.new("unary",ope).def_method
  end

  def unary2(ope,dtype,tpclass)
    Template.new("unary2",ope,
                 :dtype=>dtype,
                 :tpclass=>tpclass).def_method
  end

  def set2(ope,dtype,tpclass)
    Template.new("set2",ope,
                 :dtype=>dtype,
                 :tpclass=>tpclass).def_method(1)
  end

  def cond_binary(ope)
    Template.new("cond_binary",ope).def_binary
  end

  def cond_unary(ope)
    Template.new("cond_unary",ope).def_method
  end

  def bit_binary(ope)
    Template.new("bit_binary",ope).def_method(1)
  end

  def bit_unary(ope)
    Template.new("bit_unary",ope).def_method
  end

  def bit_count(ope)
    Template.new("bit_count",ope).def_method(-1)
  end

  def accum(ope)
    Template.new("accum",ope).def_method(-1)
  end

  def qsort(tp,dtype,dcast)
    Template.new("qsort",nil,
                 :tp=>tp,
                 :dtype=>dtype,
                 :dcast=>dcast).def_func
  end

  def def_func(ope,tmpl)
    Template.new(tmpl,ope).def_func
  end

  def def_alias(dst,src)
    Template.alias(dst,src)
  end

  def put_erb(name)
    Template.new(name,nil).erb
  end

  def math(ope,n=1)
    case n
    when 1
      Template.new("unary_s",ope).def_math(n)
    when 2
      Template.new("binary_s",ope).def_math(n)
    when 3
      Template.new("ternary_s",ope).def_math(n)
    else
      raise "invalid n=#{n}"
    end
  end

  def store_numeric
    CastNum.new("store_numeric").result
  end

  def store_array
    CastArray.new("store_array").result
  end

  def cast_array
    CastArray.new("cast_array").result2
  end

  def store_from(cname,dtype,macro)
    Cast.new("store_from",cname.downcase,dtype,"c"+cname,macro).result
  end

  def store
    Cast::HASH["store"] = t = Template.new("store","store")
    t.def_method(1)
  end
end

# ----------------------------------------------------------------------

module Delegate
  T = {}
  @@cogen = Cogen.new
  module_function
  alias method_missing_alias method_missing
  def method_missing(method, *args, &block)
    if @@cogen.respond_to? method
      @@cogen.send(method, *args, &block)
    else
      method_missing_alias(method, *args)
    end
  end
end

include Delegate