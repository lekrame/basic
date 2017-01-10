#!/usr/bin/ruby
require 'aws-sdk'
require 'optparse'

##### read command line
script = `basename "#{$0}"`.chomp
@options = {}
@options[:stackname] = "demostack" #default
OptionParser.new do |opts|
	opts.banner = "#{script} <vpc name to create> sets up a VPC with security, infrastructure, and a simple server"

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

	opts.on("-s", "--stackname NAME", "enter NAME of stack to create (dflt = \"demostack\")") do |s|
		@options[:stackname] = s
	end
end.parse!
if(ARGV.size) == 0
	abort "supply a vpc name as the command line argument\n"
end
vpcname = ARGV[0]

##### create a VPC
er = Aws::EC2::Resource.new
vpc = er.create_vpc(cidr_block: "10.9.0.0/16")
vpc.wait_until_available
er.create_tags({resources: ["#{vpc.id}"], tags: [{key: "Name", value: "#{vpcname}"}, {key: "Created", value: Time.now.to_s}]})

##### add subnets
subnet0 = vpc.create_subnet({
	cidr_block: "10.9.0.0/24",
	availability_zone: "us-west-1a"
})
subnet20 = vpc.create_subnet({
	cidr_block: "10.9.20.0/24",
	availability_zone: "us-west-1c"
})
puts "create subnet 0"
subnet0.wait_until(delay: 2, max_attempts: 9){|sub| sub.state == "available"}
puts "create subnet 20"
subnet20.wait_until(delay: 2, max_attempts: 3){|sub| sub.state == "available"}
puts "subnets are available"

##### create OpsWorks stack
if @options[:verbose]
	puts "create OpsWorks stack"
end
opsclnt = Aws::OpsWorks::Client.new( region: 'us-west-1')
instanceprofilearn = 'arn:aws:iam::718573612756:instance-profile/aws-opsworks-ec2-role '
servicerolearn = 'arn:aws:iam::718573612756:role/aws-opsworks-service-role'
itype = "t2.micro"
imgid = "ami-b73d6cd7"
stackconfigmgr = Aws::OpsWorks::Types::StackConfigurationManager.new(name: 'Chef', version: '12') # override dflt chef config (v. 11.4)
rslt = opsclnt.create_stack(name: @options[:stackname], region: 'us-west-1', default_instance_profile_arn: 
			instanceprofilearn, service_role_arn: servicerolearn, configuration_manager: stackconfigmgr, vpc_id: vpc.vpc_id, default_subnet_id: subnet0.subnet_id)
stackid = rslt.stack_id
if @options[:verbose]
	puts "Created stack #{stackname}, id = #{stackid}"
end
rslt = opsclnt.create_layer(
	stack_id: stackid, 
	type: "custom",
	name: "klayer",
	shortname: "kk"
)
klayerid = rslt.layer_id
rslt = opsclnt.create_layer(
	stack_id: stackid, 
	type: "custom",
	name: "jlayer",
	shortname: "jj"
)
jlayerid = rslt.layer_id

##### create instances

response = opsclnt.create_instance ({
	stack_id: stackid, 
  layer_ids: [jlayerid],
  instance_type: itype,
	hostname: 'krameserver',
	subnet_id: subnet0.subnet_id,
	ami_id: 'ami-be0c59de',
	availability_zone: 'us-west-1a',
	os: 'Custom'
})
iid0 = response.instance_id

response = opsclnt.create_instance ({
	stack_id: stackid, 
  layer_ids: [klayerid],
  instance_type: itype,
	hostname: 'hiddenserver',
	subnet_id: subnet20.subnet_id,
	ami_id: 'ami-be0c59de',
	availability_zone: 'us-west-1a',
	os: 'Custom'
})
iid20 = response.instance_id

puts "All built; hit <Enter> to destroy"
STDIN.gets

tokill = []
puts "terminate any instances"
vpc.subnets.each do |sn|
	sn.instances.each do |inst|
		tokill.push inst
		inst.terminate
	end
end
tokill.each do |inst|
	inst.wait_until_terminated
end

@ec2clnt.delete_network_interface({
	network_interface_id: ni_resp0.network_interface.network_interface_id 
})
@ec2clnt.delete_network_interface({
	network_interface_id: ni_resp20.network_interface.network_interface_id 
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
