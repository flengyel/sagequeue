#!/usr/bin/env python3
"""Set scoped queue/work-directory ACLs inside Podman's user namespace."""
import argparse
import json
import os
from pathlib import Path
import shutil
import stat
import subprocess
import sys
import uuid

SCHEMA=1


def bits(text):
    return (
        (4 if 'r' in text else 0)|(2 if 'w' in text else 0)|(1 if 'x' in text else 0))


def permissions(value):
    return ''.join(char if value&bit else '-' for char,bit in zip('rwx',(4,2,1)))


def parse_acl(text):
    entries={}
    for line in text.splitlines():
        line=line.split('#',1)[0].strip()
        if not line:continue
        fields=line.split(':')
        default=fields[0]=='default'
        if default:fields=fields[1:]
        if len(fields)!=3 or fields[0] not in ('user','group','mask','other'):
            raise ValueError('Unrecognized ACL entry: '+line)
        entries[(default,fields[0],fields[1])]=bits(fields[2])
    return entries


def effective_acl(entries,owner,uid,groups,owning_group):
    """Evaluate POSIX access precedence before adding a named user."""
    if uid==owner:return entries[(False,'user','')]
    mask=entries.get((False,'mask',''),7)
    named=(False,'user',str(uid))
    if named in entries:return entries[named]&mask
    matched=[]
    if owning_group in groups:matched.append(entries[(False,'group','')])
    matched.extend(value for (scope,tag,qualifier),value in entries.items()
                   if not scope and tag=='group' and qualifier and int(qualifier) in groups)
    if matched:
        value=0
        for grant in matched:value|=grant
        return value&mask
    return entries[(False,'other','')]


def merge_acl(entries,owner,users,default=False,user_groups=None,owning_group=None):
    """Grant requested bits while preserving everyone else's effective rights."""
    result=dict(entries)
    existing={key:value for key,value in result.items() if key[0]==default}
    if not existing:
        if not default:raise ValueError('Missing access ACL.')
        result.update({(True,'user',''):7,(True,'group',''):0,(True,'other',''):0})
    mask=result.get((default,'mask',''),7)
    for key,value in list(result.items()):
        scope,tag,qualifier=key
        if scope==default and (tag=='group' or tag=='user' and qualifier):
            result[key]=value&mask
    for uid,required in users.items():
        key=(default,'user',str(uid))
        previous=result.get(key,0)
        if not default and uid!=owner:
            previous=effective_acl(entries,owner,uid,(user_groups or {}).get(uid,()),owning_group)
        result[key]=previous|required
        if not default and uid==owner:
            result[(False,'user','')]=result[(False,'user','')]|required
    if default:
        # The creator must retain access when it owns an inherited inode.
        result[(True,'user','')]=result[(True,'user','')]|7
    result[(default,'mask','')]=0
    for (scope,tag,qualifier),value in result.items():
        if scope==default and (tag=='group' or tag=='user' and qualifier):
            result[(default,'mask','')]|=value
    return result


def acl_text(entries):
    return ''.join(('default:' if scope else '')+tag+':'+qualifier+':'+permissions(value)+'\n'
                   for (scope,tag,qualifier),value in sorted(entries.items()))


def checked(command,**kwargs):
    result=subprocess.run(command,capture_output=True,text=True,**kwargs)
    if result.returncode:
        raise ValueError('ACL command failed: '+(result.stderr.strip() or result.stdout.strip()))
    return result.stdout


def repair_acl(path,uid,required,inherit=False,user_groups=None):
    info=path.lstat()
    if stat.S_ISLNK(info.st_mode):return
    entries=parse_acl(checked(['getfacl','-c','-p','-n','--',str(path)]))
    users={0:required,uid:required}
    updated=merge_acl(entries,info.st_uid,users,user_groups=user_groups,owning_group=info.st_gid)
    if inherit:updated=merge_acl(updated,info.st_uid,{0:7,uid:7},default=True)
    if updated!=entries:
        checked(['setfacl','--physical','--no-mask','--set-file=-','--',str(path)],input=acl_text(updated))


def contained(boundary,path):
    path=Path(path).resolve()
    if not path.is_relative_to(boundary):
        raise ValueError('ACL path is outside the notebook mount: '+str(path))
    return path


def ancestors(boundary,path,uid,user_groups=None):
    chain=[]
    while path.is_relative_to(boundary):
        chain.append(path)
        if path==boundary:break
        path=path.parent
    for directory in reversed(chain):
        # Host access is already required to submit the task; keep its rights.
        repair_acl(directory,uid,1,user_groups=user_groups)


def repair(boundary,queue,uid,workdir=None,script=None,tree=None,force=False,gids=()):
    boundary=Path(boundary).resolve()
    queue=contained(boundary,queue)
    workdir=contained(boundary,workdir) if workdir else None
    script=contained(boundary,script) if script else None
    tree=contained(boundary,tree) if tree else None
    if tree is not None and not tree.is_relative_to(queue):
        raise ValueError('Attempt tree is outside this queue.')
    # Validate every requested target before changing any ACL.
    if not boundary.is_dir() or not queue.is_dir():raise ValueError('Notebook and queue directories must exist.')
    if workdir is not None and not workdir.is_dir():raise ValueError('Task working directory is missing.')
    if script is not None and not script.is_file():raise ValueError('Task script is missing.')
    if tree is not None and not tree.is_dir():raise ValueError('Attempt directory is missing.')
    if uid<0:raise ValueError('Container UID must be nonnegative.')
    if any(gid<0 for gid in gids):raise ValueError('Container GIDs must be nonnegative.')
    user_groups={0:set(os.getgroups())|{os.getgid()},uid:set(gids)}
    if uid==0:user_groups[0].update(os.getgroups()+[os.getgid()])
    for tool in ('setfacl','getfacl'):
        if shutil.which(tool) is None:raise ValueError('Missing '+tool+'; install the host acl package.')
    # Test the filesystem on a disposable inode before touching shared paths.
    probe=queue/('permissions-probe.'+uuid.uuid4().hex+'.tmp')
    try:
        with probe.open('x'):pass
        repair_acl(probe,uid,6,user_groups=user_groups)
    finally:
        probe.unlink(missing_ok=True)
    ancestors(boundary,queue.parent,uid,user_groups)
    repair_acl(queue,uid,7,inherit=True,user_groups=user_groups)
    marker=queue/'permissions.json'
    expected={'schema':SCHEMA,'container_uid':uid,'boundary':str(boundary),'queue':str(queue)}
    try:prepared=not marker.is_symlink() and json.loads(marker.read_text())==expected
    except (OSError,ValueError):prepared=False
    roots=[tree] if tree is not None else []
    if force or not prepared:roots=[queue]
    for root in roots:
        for current,directories,files in os.walk(root,followlinks=False):
            current=Path(current)
            directories[:]=[name for name in directories if not (current/name).is_symlink()]
            repair_acl(current,uid,7,inherit=True,user_groups=user_groups)
            for name in files:
                path=current/name
                info=path.lstat()
                if stat.S_ISREG(info.st_mode):
                    repair_acl(path,uid,7 if info.st_mode&0o111 else 6,user_groups=user_groups)
    if workdir is not None:
        ancestors(boundary,workdir.parent,uid,user_groups)
        repair_acl(workdir,uid,7,inherit=True,user_groups=user_groups)
    if script is not None:
        ancestors(boundary,script.parent.parent,uid,user_groups)
        # Python's FileFinder lists this directory, even with an explicit path.
        repair_acl(script.parent,uid,5,user_groups=user_groups)
        repair_acl(script,uid,4,user_groups=user_groups)
    if force or not prepared:
        temporary=queue/('permissions.'+uuid.uuid4().hex+'.tmp')
        with temporary.open('x') as stream:
            json.dump(expected,stream);stream.write('\n');stream.flush();os.fsync(stream.fileno())
        temporary.replace(marker)


def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--boundary',type=Path,required=True);p.add_argument('--queue',type=Path,required=True)
    p.add_argument('--uid',type=int,required=True);p.add_argument('--workdir',type=Path)
    p.add_argument('--gid',type=int,action='append',default=[],help='Actual container group ID (repeatable).')
    p.add_argument('--script',type=Path);p.add_argument('--tree',type=Path)
    p.add_argument('--force',action='store_true');a=p.parse_args()
    try:repair(a.boundary,a.queue,a.uid,a.workdir,a.script,a.tree,a.force,a.gid)
    except (ValueError,OSError) as error:
        print(str(error),file=sys.stderr);return 2
    return 0


if __name__=='__main__':sys.exit(main())
