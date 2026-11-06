import time
import oci

config = oci.config.from_file()
compute_client = oci.core.ComputeClient(config)

TENANCY_OCID = config["tenancy"]
AVAILABILITY_DOMAIN = "izDz:AP-HYDERABAD-1-AD-1"
SUBNET_ID = "ocid1.subnet.oc1.ap-hyderabad-1.aaaaaaaaxysx22ozumttrploiqs2zjbujhqhk5higxkmmgaap3f5zzficvwq"
SHAPE = "VM.Standard.A1.Flex"
IMAGE_ID = "ocid1.image.oc1.ap-hyderabad-1.aaaaaaaamvzbsljz2ja6iegrtbe2hak37xuahdhb6uylqnw37iyq7zgvrjqq"
DEFAULT_SSH_PUBLIC_KEY = (
    "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQDuXnceKvdpz1yeWMpC9h0YPg7thZQXtigXt/"
    "9ZOpjBzF7HS1niz3oiAu9Ok3zM9s5aNIZz9lFjU9UMX4DnT5mYVEyzsiw8wgQYaQfgz/zsRyRAE"
    "7QZHDPhdqE/yHY0vsshmvg75CHzdNl6vbPW4EXkE7CSTASYHw8EY6cJQdT33p3FfpKFyn1cy+pM"
    "7rerVEgqRYuvcOtbzpT6PMzGy9OSdEQudKR1la1DidabbpiQ4YgCQl1faRdhJAcNwE3oMZu8iqkp"
    "1XiqCQHyUCFoiu53Re19yinpa8Og0gwnCFUSF16n0z6qdS52VQOXCPomwNJhTE+jwVy46IKhlX4"
    "Pxrqr ssh-key-2026-10-01"
)

candidates = [
    {"ocpus": 2.0, "memory_in_gbs": 12.0, "label": "2 OCPUs / 12 GB RAM"},
    {"ocpus": 1.0, "memory_in_gbs": 6.0, "label": "1 OCPU / 6 GB RAM"}
]

for cand in candidates:
    print(f"Trying launch with {cand['label']}...")
    launch_details = oci.core.models.LaunchInstanceDetails(
        compartment_id=TENANCY_OCID,
        availability_domain=AVAILABILITY_DOMAIN,
        display_name=f"coroute-ampere-{int(time.time())}",
        shape=SHAPE,
        shape_config=oci.core.models.LaunchInstanceShapeConfigDetails(
            ocpus=cand["ocpus"],
            memory_in_gbs=cand["memory_in_gbs"],
        ),
        create_vnic_details=oci.core.models.CreateVnicDetails(
            subnet_id=SUBNET_ID,
            assign_public_ip=True,
            display_name="primary-vnic",
        ),
        source_details=oci.core.models.InstanceSourceViaImageDetails(
            source_type="image",
            image_id=IMAGE_ID,
            boot_volume_size_in_gbs=50,
        ),
        metadata={
            "ssh_authorized_keys": DEFAULT_SSH_PUBLIC_KEY,
        },
    )

    try:
        res = compute_client.launch_instance(launch_details)
        print(">>> SUCCESS! Instance allocated:", res.data.id)
        break
    except oci.exceptions.ServiceError as e:
        print(f"Failed with {cand['label']}: status={e.status}, code={e.code}, msg={e.message}")
