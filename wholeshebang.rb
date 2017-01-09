#!/usr/bin/ruby
require 'aws-sdk'
require 'optparse'

##### read command line
script = `basename "#{$0}"`.chomp
@options = {}
OptionParser.new do |opts|
	opts.banner = "#{script} sets up a VPC with security, infrastructure, and a simple server"

	opts.on("-h", "--help", "show help text") do
		puts opts
		exit
	end

	opts.on("-v", "--verbose", "show more details of setup steps") do
		@options[:verbose] = true
	end

	opts.on("-c", "--cidr CIDRBLOCK", "enter CIDR of computers to be allowed access to test server") do |c|
		@options[:cidr] = c
	end
end.parse!
if(ARGV.size) == 0
	abort "supply the stack name as a command line argument\n"
end
stackname = ARGV[0]

##### create a VPC
waitrSetting = Aws::Waiters::Waiter.new({:delay => 2, :max_attempts => 30})
er = Aws::EC2::Resource.new
vpc = er.create_vpc(cidr_block: "10.9.0.0/16")
vpc.wait_until_available
er.create_tags({resources: ["#{vpc.id}"], tags: [{key: "Name", value: "tmpvpc"}, {key: "Created", value: Time.now.to_s}]})

##### add subnets
subnet0 = vpc.create_subnet({
	cidr_block: "10.9.0.0/24",
	availability_zone: "us-west-1a"
})
subnet20 = vpc.create_subnet({
	cidr_block: "10.9.20.0/24",
	availability_zone: "us-west-1c"
})
vpc.wait_until(delay: waitrSetting.delay, max_attempts: waitrSetting.max_attempts){|v| v.state == "available"}
puts "create subnet 0"
subnet0.wait_until(delay: 2, max_attempts: 9){|sub| sub.state == "available"}
#subnet0.wait_until(delay: 2, max_attempts: 9){|sub| until sub.state == "available"; puts "waiting for subnet 0"; puts subnet0.state.inspect ; sleep 1; end}
puts "create subnet 20"
subnet20.wait_until(delay: 2, max_attempts: 3){|sub| sub.state == "available"}
#subnet0.wait_until({"delay" => 2, "max_attempts" => 3}){|sub| until sub.subnet_id == "available"; sleep 1}
#subnet20.wait_until({"delay" => 2, "max_attempts" => 3}){|sub| until sub.subnet_id == "available"; sleep 1}
puts "subnets are available"


=begin comment
#add network ACLs, if they are worth the price (security groups alone are fine, but if DDOS attacks are a concern, ACLs are better)
acl_0_in = vpc.create_network_acl #for incoming, public subnet
acl_0_in.create_entry({ rule_number: 100, protocol: 'tcp', rule_action: "allow", egress: false, cidr_block: "0.0.0.0/0", port_range: { from: 80, to: 80, } }) #incoming HTTP;
...
puts "Waiting for ACLs"
acl_0_in.wait_until({delay : 2, max_attempts : 3}) { |aclassoc| !aclassoc.empty }
...
=end comment
if @options[:verbose]
	puts "Subnets (and any ACLs) are ready.  Hit <Enter> to proceed"
	STDIN.gets
end

@ec2clnt = Aws::EC2::Client.new(region: 'us-west-1')
ni_resp = @ec2clnt.create_network_interface({
  description: "netface", 
  subnet_id: subnet0.subnet_id
})

##### create instance
ec2res = Aws::EC2::Resource.new(region: 'us-west-1')
instanceprofilearn = 'arn:aws:iam::718573612756:instance-profile/aws-opsworks-ec2-role '
servicerolearn = 'arn:aws:iam::718573612756:role/aws-opsworks-service-role'
itype = "t2.micro"
imgid = "ami-b73d6cd7"

ec2res.create_instances({
	image_id: imgid,
	min_count: 1,
  max_count: 1,
	instance_type: itype,
	network_interfaces: [{device_index: 0, network_interface_id:  ni_resp.network_interface.network_interface_id}]
})
puts "All build; hit <Enter> to destroy"
STDIN.gets

puts "terminate any instances"
vpc.subnets.each do |sn|
	sn.instances.each do |inst|
		inst.terminate
		inst.wait_until_terminated
	end
end

@ec2clnt.delete_network_interface({
	network_interface_id: ni_resp.network_interface.network_interface_id 
})
def loseTheSubnet(subnetInst)
	if @options[:verbose]
		puts "delete subnet with id #{subnetInst.subnet_id}"
	end
	subnetInst.delete
	sleep 2
end
if @options[:verbose]
	puts "terminate subnets"
end
begin
	vpc.subnets.each do |sn|
		loseTheSubnet(sn)
	end
rescue InvalidSubnetIDNotFound
	puts "subnet id %s not found" 
ensure
	puts "proceeding"
	vpc.subnets.each do |sn|
		loseTheSubnet(sn)
	end
	sleep 2
	vpc.delete
end
exit
##### create OpsWorks stack
if @options[:verbose]
	puts "create OpsWorks stack"
end
clnt = Aws::OpsWorks::Client.new( region: 'us-west-1')
stackconfigmgr = Aws::OpsWorks::Types::StackConfigurationManager.new(name: 'Chef', version: '12') # override dflt chef config (v. 11.4)
rslt = clnt.create_stack(name: stackname, region: 'us-west-1', default_instance_profile_arn: 
			instanceprofilearn, service_role_arn: servicerolearn, configuration_manager: stackconfigmgr)
stackid = rslt.stack_id
if @options[:verbose]
	puts "Created stack #{stackname}, id = #{stackid}"
end
rslt = clnt.create_layer(
	stack_id: stackid, 
	type: "custom",
	name: "klayer",
	shortname: "kk"
)
if @options[:verbose]
	puts "Created layer \"klayer\", result: #{rslt.inspect}"
end
rslt = clnt.create_layer(
	stack_id: stackid, 
	type: "custom",
	name: "jlayer",
	shortname: "jj"
)
jlayerid = rslt.layer_id
if @options[:verbose]
	
end
if @options[:verbose]
	puts "Created layer \"jlayer\", result: #{rslt.inspect}"
end

#resp = ec2 = Aws::EC2::Client.new(region: 'us-west-1')
##### create instance
ec2res = Aws::EC2::Resource.new(region: 'us-west-1')
instanceprofilearn = 'arn:aws:iam::718573612756:instance-profile/aws-opsworks-ec2-role '
servicerolearn = 'arn:aws:iam::718573612756:role/aws-opsworks-service-role'
itype = "t2.micro"
imgid = "ami-b73d6cd7"

ec2res.create_instances({
	image_id: imgid,
	min_count: 1,
  max_count: 1,
	instance_type: itype,
	network_interfaces: [{subnet_id: subnet0.subnet_id}]
})
=begin
clnt.create_instance ({
	stack_id: stackid, 
  layer_ids: [jlayerid],
  instance_type: itype,
	hostname: 'krameserver',
	subnet_id: 'subnet-fe56699b',
	ami_id: 'ami-be0c59de',
	availability_zone: 'us-west-1a',
	#:virtualization_type: 'paravirtual',
	os: 'Ubuntu 14.04 LTS'
})
=end
exit
instanceprofilearn = 'arn:aws:iam::718573612756:instance-profile/aws-opsworks-ec2-role '
servicerolearn = 'arn:aws:iam::718573612756:role/aws-opsworks-service-role'
clnt = Aws::OpsWorks::Client.new( region: 'us-west-1')
#clnt = Aws::OpsWorks::Client.new( region: 'us-west-1', http_wire_trace: true )
stackconfigmgr = Aws::OpsWorks::Types::StackConfigurationManager.new(name: 'Chef', version: '12') # override dflt chef config (v. 11.4)
rslt = clnt.create_stack(name: stackname, region: 'us-west-1', default_instance_profile_arn: 
			instanceprofilearn, service_role_arn: servicerolearn, configuration_manager: stackconfigmgr)
stackid = rslt.stack_id
puts "Created stack #{stackname}, id = #{stackid}"
rslt = clnt.create_layer(
	stack_id: stackid, 
	type: "custom",
	name: "klayer",
	shortname: "kk"
)
puts "Created layer \"klayer\", result: #{rslt.inspect}"
rslt = clnt.create_layer(
	stack_id: stackid, 
	type: "custom",
	name: "jlayer",
	shortname: "jj"
)
jlayerid = rslt.layer_id
puts "Created layer \"jlayer\", result: #{rslt.inspect}"

#resp = ec2 = Aws::EC2::Client.new(region: 'us-west-1')
itype = "t2.micro"
#inst = Aws::OpsWorks::Types::Instance.new({
#	stack_id: stackid, 
#  layer_ids: [jlayerid],
#  instance_type: itype,
#	hostname: 'krameserver',
#	subnet_id: 'subnet-fe56699b',
#	ami_id: 'ami-be0c59de',
#	os: 'Ubuntu 14.04 LTS'
#})
#clnt.create_instance (inst)
clnt.create_instance ({
	stack_id: stackid, 
  layer_ids: [jlayerid],
  instance_type: itype,
	hostname: 'krameserver',
	subnet_id: 'subnet-fe56699b',
#	ami_id: 'ami-be0c59de',
	availability_zone: 'us-west-1a',
	#:virtualization_type: 'paravirtual',
	os: 'Ubuntu 14.04 LTS'
})
puts "instance request: #{resp.inspect}"
exit
