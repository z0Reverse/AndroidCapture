使用方法：
1、chmod赋予权限
2、./脚本名字.sh 进程id 转发的ip地址
	eg: ./redirect.sh u0_a203 127.0.0.1
3、只会针对目标app做代理转发，测试完毕记得清楚转发
	./redirect -F
```sh
#!/system/bin/sh

function usage(){
    echo "Usage: `basename $0` [-F] uid ip"
}

if [ $# != 2 -a $# != 1 ]  
then
    usage
    exit 55     
fi 


while getopts "AF" opt; do
  case $opt in
    F)
      echo "delete all redirect rule!" 
      iptables -t nat -F
      exit 0
      ;;
    A)
      echo "redirect all tcp traffic" 
      iptables -t nat -F

      iptables  -t nat -A OUTPUT -p tcp  -j DNAT --to-destination $2:8080
      iptables  -t nat -A POSTROUTING -p tcp  -j MASQUERADE
      exit 0
      ;;
    \?)
      echo "Invalid option: -$OPTARG" 
      exit 0
      ;;
  esac
done


if [ $# == 2  ]  
then

	echo " uid: "$1"    ip: "$2

	iptables -t nat -A OUTPUT -p tcp -m owner --uid-owner $1  -j DNAT --to-destination $2:8080
  iptables -t nat -A POSTROUTING -p tcp -m owner --uid-owner $1 -j MASQUERADE
  exit 0
        
fi 

```