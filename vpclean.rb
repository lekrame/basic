#!/usr/bin/ruby
require 'aws-sdk'
require 'optparse'

#######################
##                   ##
## READ COMMAND LINE ##
##                   ##
#######################
script = `basename "#{$0}"`.chomp
@options = {}
OptionParser.new do |opts|
	opts.banner = "#{script} deletes a VPC"
	opts.on("-h", "--help", "show help text") do
		puts opts
		exit
	end
	opts.on("-v", "--verbose", "show more details of setup and takedown steps") do
		@options[:verbose] = true
	end
end.parse!

if(ARGV.size) == 0
	abort "supply the VPC name as a command line argument\n"
end
@vpcname = ARGV[0]

##################
##              ##
## FIND THE VPC ##
##              ##
##################
waitr = Aws::Waiters::Waiter.new({:delay => 2, :max_attempts => 60})
@owclient = Aws::OpsWorks::Client.new
@ec2client = Aws::EC2::Client.new
resp = @ec2client.describe_vpcs
resp.vpcs.each do |vpc|
	@nameIdx = vpc.tags.find_index{|tt| tt.key == "Name"}
	if vpc.tags[@nameIdx].value == @vpcname
			@vpcid = vpc.vpc_id; 
			@vpctogo = vpc;
			break
	end
end
if @vpcid.nil? 
	abort "VPC named %s not found" %ARGV[0].chomp
end
puts "found VPC named %s with ID %s\nDelete? [N]" % [@vpctogo.tags[@nameIdx].value,  @vpcid]; 
STDIN.gets; 
exit unless $_ =~ /^[yY]/

def loseTheSubnet(subnetId)
	if @options[:verbose]
		puts "delete subnet with id #{subnetId}"
	end
	@ec2client.delete_subnet({
 		subnet_id: subnetId 
	})
	sleep 2
end

#########################################
##                                     ##
## COLLECT OPSWORKS STRUCTURES TO KILL ##
##                                     ##
#########################################
# first, find all stacks in the vpc
mystacks = []
@stackids_to_delete = []
mystacks = @owclient.describe_stacks().stacks
mystacks.each do |stk|
	@stackids_to_delete.push(stk.stack_id) if stk.vpc_id == @vpcid
end

###############################
##                           ##
## COLLECT INSTANCES TO KILL ##
##                           ##
###############################
if @options[:verbose]
	puts "terminate any instances"
end
@instances_to_delete = []
@stackids_to_delete.each do |sid|
	layerids_to_delete = []
	instanceids_to_delete = []
	@instances_to_delete.push(@owclient.describe_instances({ stack_id: sid }).instances)
#	@instances_to_delete.sort!.uniq!
	@instances_to_delete.each do |inst|
		@owclient.stop_instance({instance_id: inst.instance_id})
		instanceids_to_delete.push(inst.instance_id)
	end
	@owclient.wait_until(:instance_stopped, {:instance_ids => instanceids_to_delete})
	instanceids_to_delete.each do |iid|
		@owclient.terminate_instance({instance_id: iid})
	end
	@owclient.wait_until(:instance_terminated, {:instance_ids => instanceids_to_delete})
	layers_to_delete = @owclient.describe_layers({stack_id: sid }).layers
	layers_to_delete.each do |layer|
		layerids_to_delete.push(layer.layer_id)
		@owclient.delete_layer({layer_id: layer.layer_id})
	end
	@owclient.delete_stack(stack_id: sid)
end


####################
##                ##
## DELETE SUBNETS ##
##                ##
####################
sbnts = @ec2client.describe_subnets
sbnts.subnets.each do |sbnt|
	if sbnt.vpc_id == @vpcid
		loseTheSubnet(sbnt.subnet_id)
	end
end

############################
##                        ##
## DELETE SECURITY GROUPS ##
##                        ##
############################
sec_grps = @ec2client.describe_security_groups({
	filters:[
		{name: "vpc-id", values: [@vpcid]}
	]
}).security_groups.each do |sgp|
	@ec2client.delete_security_group({group_id: sgp.group_id}) if sgp.group_name != "default"
end

@ec2client.delete_vpc(:vpc_id => @vpcid)
