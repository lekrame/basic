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
@options[:age] = 14400 #default 4 hours
OptionParser.new do |opts|
	opts.banner = "#{script} deletes a VPC"
	opts.on("-h", "--help", "show help text") do
		puts opts
		exit
	end
	opts.on("-v", "--verbose", "show more details of setup and takedown steps") do
		@options[:verbose] = true
	end
	opts.on("-a", "--age SECS", "how many seconds back since creation of earliest stuff to delete") do |a|
		@options[:age] = a
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
	@instances_to_delete.concat(@owclient.describe_instances({ stack_id: sid }).instances)
#	@instances_to_delete.sort!.uniq!
	@instances_to_delete.each do |inst|
		@owclient.stop_instance({instance_id: inst.instance_id})
		instanceids_to_delete.push(inst.instance_id)
	end
	@owclient.wait_until(:instance_stopped, {:instance_ids => instanceids_to_delete}) if instanceids_to_delete.length > 0
	instanceids_to_delete.each do |iid|
		@owclient.terminate_instance({instance_id: iid})
	end
	@owclient.wait_until(:instance_terminated, {:instance_ids => instanceids_to_delete}) if instanceids_to_delete.length > 0
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

#### delete roles and policies
iamclient = Aws::IAM::Client.new
instprofs = iamclient.list_instance_profiles.instance_profiles
instprofs.each do |i|
	if (i.create_date <=> (Time.now - @options[:age])) == 1
		i.roles.each do |r|
			iamclient.remove_role_from_instance_profile({
			  instance_profile_name: i.instance_profile_name, 
			  role_name: r.role_name, 
			})
		end
		iamclient.delete_instance_profile(instance_profile_name: i.instance_profile_name)
	end
end
roles = iamclient.list_roles.roles
roles.each do |r|
	if (r.create_date<=>(Time.now - @options[:age])) == 1
		policies = iamclient.list_attached_role_policies({ role_name: r.role_name }).attached_policies
		policies.each do |p|
			iamclient.detach_role_policy({
	  		role_name: r.role_name,
	  		policy_arn: p.policy_arn
			})
		end
		iamclient.delete_role({role_name: r.role_name}) 
	end
end
policies = iamclient.list_policies.policies
policies.each do |p|
	iamclient.delete_policy(policy_arn: p.arn) if (p.create_date<=>(Time.now - @options[:age])) == 1
end

@ec2client.delete_vpc(:vpc_id => @vpcid)
