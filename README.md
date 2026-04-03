# virtio-win

WHQL signed virtio-win.iso from RHEL. Inspired by [qemus/virtiso-whql](https://github.com/qemus/virtiso-whql).

# Highlights

- maintenance-free
  - no hardcoded content set name and offset, no matter EL5/6/7/8/9/10 or beta/GA/EUS/E4S
- for archival
  - vanilla official iso, no trim down
  - old releases are also available

# Known issues

- cannot access repository snapshot via RHSM API, no consistency guarantee
- HTTP status code 429 on first run

# References

- [Getting started with Red Hat APIs](https://access.redhat.com/articles/3626371)
- [Red Hat API Tokens](https://access.redhat.com/management/api)
- [RHSM API Swagger Documentation](https://access.redhat.com/management/api/rhsm)
