type t = {
  name : string;
  description : string option;
  parameters : Jsonkit.t;
  provider_options : Provider_options.t;
}
